// Writes the expected output of server/public/epd.js for a fixed input, so the
// iPhone app's unit test can prove its JavaScriptCore run of the same file is
// byte-identical to what the web page produces.
//
//   node ios/tools/make-epd-fixture.mjs
//
// Re-run it whenever epd.js changes; the test fails until you do.

import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { adjust, dither, pack, toRGBA, viewSize } from '../../server/public/epd.js';

const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');

// Must match PhotoframeTests/EPDTests.swift `fixtureRGBA`. Integer-only so both
// languages build exactly the same bytes.
function fixtureRGBA(width, height) {
  const rgba = new Uint8ClampedArray(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const p = (y * width + x) * 4;
      rgba[p] = (x * 3 + y * 5) % 256;
      rgba[p + 1] = (x * y + 7 * x) % 256;
      rgba[p + 2] = ((x ^ y) * 11) % 256;
      rgba[p + 3] = 255;
    }
  }
  return rgba;
}

const cases = [
  { orientation: 'landscape', flip: false, contrast: 1.15, saturation: 1.3 },
  { orientation: 'portrait', flip: true, contrast: 1, saturation: 1 },
  { orientation: 'landscape', flip: true, contrast: 1.6, saturation: 0.6 },
  { orientation: 'portrait', flip: false, contrast: 0.8, saturation: 2 },
];

const out = cases.map((c) => {
  const { width, height } = viewSize(c.orientation);
  const input = fixtureRGBA(width, height);
  const inputHash = sha(input);
  // Same steps, in the same order, as render() and the send handler in app.js.
  adjust(input, { contrast: c.contrast, saturation: c.saturation });
  const indices = dither(input, width, height);
  const frame = pack(indices, c.orientation, c.flip);
  return {
    ...c,
    width,
    height,
    inputSHA256: inputHash,
    indicesSHA256: sha(indices),
    previewSHA256: sha(toRGBA(indices, 'rgb')),
    frameSHA256: sha(frame),
  };
});

const path = new URL('../PhotoframeTests/epd-fixture.json', import.meta.url);
writeFileSync(path, JSON.stringify(out, null, 2) + '\n');
console.log(`wrote ${path.pathname} (${out.length} cases)`);
