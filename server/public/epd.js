// Image pipeline for the 7.3" Spectra 6 panel: tone adjustment, dithering to
// the six inks, and packing into the byte layout the panel expects.
//
// Pure functions on typed arrays, no DOM, so the same code runs in the browser,
// in Node tests, and later in the Worker for text-to-frame.

export const PANEL_W = 800;
export const PANEL_H = 480;
export const FRAME_BYTES = (PANEL_W * PANEL_H) / 2;

// `code` is the 4-bit value the panel controller uses for each ink (4 is
// unused). `rgb` approximates how the ink looks on the real panel, which is
// much duller than a pure primary; dithering against these gives truer colour
// than dithering against pure red/green/blue. `ideal` is for on-screen display.
export const INKS = [
  { name: 'black',  code: 0, rgb: [25, 30, 33],    ideal: [0, 0, 0] },
  { name: 'white',  code: 1, rgb: [232, 232, 232], ideal: [255, 255, 255] },
  { name: 'yellow', code: 2, rgb: [239, 222, 68],  ideal: [255, 255, 0] },
  { name: 'red',    code: 3, rgb: [178, 19, 24],   ideal: [255, 0, 0] },
  { name: 'blue',   code: 5, rgb: [33, 87, 186],   ideal: [0, 0, 255] },
  { name: 'green',  code: 6, rgb: [18, 95, 32],    ideal: [0, 255, 0] },
];

// Pixels whose channels differ by less than this count as (partly) grey, and
// NEUTRAL_BIAS is how strongly fully grey pixels avoid the coloured inks.
const NEUTRAL_CHROMA = 48;
const NEUTRAL_BIAS = 8;

const VALID_CODES = new Set(INKS.map((ink) => ink.code));
const CODE_TO_INDEX = new Int8Array(16).fill(-1);
INKS.forEach((ink, i) => { CODE_TO_INDEX[ink.code] = i; });

/** Size of the picture as the viewer sees it for a given frame orientation. */
export function viewSize(orientation) {
  return orientation === 'portrait'
    ? { width: PANEL_H, height: PANEL_W }
    : { width: PANEL_W, height: PANEL_H };
}

/**
 * Contrast and saturation in place on RGBA data. Both are multipliers where 1
 * leaves the image alone. E-paper inks are muted, so a little extra of each
 * usually helps.
 */
export function adjust(rgba, { contrast = 1, saturation = 1 } = {}) {
  if (contrast === 1 && saturation === 1) return rgba;
  for (let i = 0; i < rgba.length; i += 4) {
    let r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    const luma = 0.299 * r + 0.587 * g + 0.114 * b;
    r = luma + (r - luma) * saturation;
    g = luma + (g - luma) * saturation;
    b = luma + (b - luma) * saturation;
    rgba[i]     = clamp((r - 128) * contrast + 128);
    rgba[i + 1] = clamp((g - 128) * contrast + 128);
    rgba[i + 2] = clamp((b - 128) * contrast + 128);
  }
  return rgba;
}

/**
 * Floyd-Steinberg dither of RGBA data to the six inks.
 * Returns one ink index (into INKS) per pixel.
 */
export function dither(rgba, width, height, palette = INKS.map((ink) => ink.rgb)) {
  const out = new Uint8Array(width * height);
  const isGrey = palette.map(([r, g, b]) => Math.max(r, g, b) - Math.min(r, g, b) < 24);
  // Error rows for the current and next line, padded one pixel each side.
  let cur = new Float32Array((width + 2) * 3);
  let next = new Float32Array((width + 2) * 3);

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const p = (y * width + x) * 4;
      const e = (x + 1) * 3;
      const r = clamp(rgba[p] + cur[e]);
      const g = clamp(rgba[p + 1] + cur[e + 1]);
      const b = clamp(rgba[p + 2] + cur[e + 2]);

      // How grey the original pixel is: 1 for neutral, 0 once clearly coloured.
      const o0 = rgba[p], o1 = rgba[p + 1], o2 = rgba[p + 2];
      const chroma = Math.max(o0, o1, o2) - Math.min(o0, o1, o2);
      const neutral = chroma >= NEUTRAL_CHROMA ? 0 : 1 - chroma / NEUTRAL_CHROMA;

      const idx = nearest(r, g, b, palette, neutral, isGrey);
      out[y * width + x] = idx;

      const er = r - palette[idx][0];
      const eg = g - palette[idx][1];
      const eb = b - palette[idx][2];
      spread(cur, e + 3, er, eg, eb, 7 / 16);
      spread(next, e - 3, er, eg, eb, 3 / 16);
      spread(next, e, er, eg, eb, 5 / 16);
      spread(next, e + 3, er, eg, eb, 1 / 16);
    }
    [cur, next] = [next, cur];
    next.fill(0);
  }
  return out;
}

/**
 * Packs ink indices into the panel's native layout: 800x480, 4 bits per pixel,
 * left pixel in the high nibble.
 *
 * The panel is mounted so that its native "up" is not the viewer's "up". The
 * default transforms match Waveshare's firmware (landscape is rotated 180
 * degrees, portrait 90 degrees counter-clockwise). `flip` turns the picture a
 * further 180 degrees for a frame that stands the other way up.
 */
export function pack(indices, orientation = 'landscape', flip = false) {
  const { width, height } = viewSize(orientation);
  if (indices.length !== width * height) throw new Error('wrong pixel count for orientation');
  const frame = new Uint8Array(FRAME_BYTES);

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const vx = flip ? width - 1 - x : x;
      const vy = flip ? height - 1 - y : y;
      let px, py;
      if (orientation === 'portrait') {
        px = vy;
        py = PANEL_H - 1 - vx;
      } else {
        px = PANEL_W - 1 - vx;
        py = PANEL_H - 1 - vy;
      }
      const code = INKS[indices[y * width + x]].code;
      const at = py * (PANEL_W / 2) + (px >> 1);
      frame[at] |= (px & 1) ? code : code << 4;
    }
  }
  return frame;
}

/** Reverses pack(): panel bytes back to ink indices in viewer orientation. */
export function unpack(frame, orientation = 'landscape', flip = false) {
  const { width, height } = viewSize(orientation);
  const indices = new Uint8Array(width * height);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const vx = flip ? width - 1 - x : x;
      const vy = flip ? height - 1 - y : y;
      let px, py;
      if (orientation === 'portrait') {
        px = vy;
        py = PANEL_H - 1 - vx;
      } else {
        px = PANEL_W - 1 - vx;
        py = PANEL_H - 1 - vy;
      }
      const byte = frame[py * (PANEL_W / 2) + (px >> 1)];
      indices[y * width + x] = CODE_TO_INDEX[(px & 1) ? byte & 0x0f : byte >> 4];
    }
  }
  return indices;
}

/** True if `frame` is the right size and every pixel is a real ink code. */
export function isValidFrame(frame) {
  if (frame.length !== FRAME_BYTES) return false;
  for (let i = 0; i < frame.length; i++) {
    if (!VALID_CODES.has(frame[i] >> 4) || !VALID_CODES.has(frame[i] & 0x0f)) return false;
  }
  return true;
}

/** Ink indices to RGBA for display. `look` is 'rgb' (as on the panel) or 'ideal'. */
export function toRGBA(indices, look = 'rgb') {
  const rgba = new Uint8ClampedArray(indices.length * 4);
  for (let i = 0; i < indices.length; i++) {
    const c = INKS[indices[i]][look];
    rgba[i * 4] = c[0];
    rgba[i * 4 + 1] = c[1];
    rgba[i * 4 + 2] = c[2];
    rgba[i * 4 + 3] = 255;
  }
  return rgba;
}

/** Convenience: adjusted RGBA in viewer orientation straight to panel bytes. */
export function encode(rgba, { orientation = 'landscape', flip = false, contrast = 1, saturation = 1 } = {}) {
  const { width, height } = viewSize(orientation);
  const work = new Uint8ClampedArray(rgba);
  adjust(work, { contrast, saturation });
  const indices = dither(work, width, height);
  return { indices, frame: pack(indices, orientation, flip) };
}

// Mid grey is numerically closer to blue ink than to black or white, so a
// plain nearest-colour search paints grey skies and walls as blue and yellow
// speckle. Coloured inks are made to look further away the greyer the original
// pixel is, which leaves neutral areas to black and white.
function nearest(r, g, b, palette, neutral, isGrey) {
  let best = 0;
  let bestDist = Infinity;
  const penalty = 1 + neutral * NEUTRAL_BIAS;
  for (let i = 0; i < palette.length; i++) {
    const dr = r - palette[i][0];
    const dg = g - palette[i][1];
    const db = b - palette[i][2];
    // "Redmean" weighting: a cheap approximation of perceived colour distance.
    const rm = (r + palette[i][0]) / 2;
    let d = (2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db;
    if (!isGrey[i]) d *= penalty;
    if (d < bestDist) { bestDist = d; best = i; }
  }
  return best;
}

function spread(row, at, er, eg, eb, k) {
  row[at] += er * k;
  row[at + 1] += eg * k;
  row[at + 2] += eb * k;
}

function clamp(v) {
  return v < 0 ? 0 : v > 255 ? 255 : v;
}
