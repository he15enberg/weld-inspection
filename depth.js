/* Colourising a stored depth.u16 onto a canvas.
 *
 * Same turbo ramp as the phone, so the depth view reads identically in both
 * places. Two decisions carried over:
 *
 *   The ramp is normalised to THIS frame's near and far, not a fixed range. A
 *   weld at 300 mm against a bench at 900 mm otherwise renders as two flat
 *   bands with no shape in either.
 *
 *   No smoothing. Every pixel here is a real measurement, and interpolating
 *   between them would imply resolution the sensor does not have -- so
 *   imageSmoothingEnabled stays off and the canvas is scaled by CSS.
 */

const RAMP = [
  0x30123B, 0x4145AB, 0x4675ED, 0x39A2FC, 0x1BCFD4,
  0x24ECA6, 0x61FC6C, 0xA4FC3B, 0xD1E834, 0xF3C63A,
  0xFE9B2D, 0xF36315, 0xD93806, 0xB11901, 0x7A0403,
];

function rampAt(t) {
  const x = Math.min(Math.max(t, 0), 1) * (RAMP.length - 1);
  const i = Math.min(Math.floor(x), RAMP.length - 2);
  const f = x - i;
  const a = RAMP[i];
  const b = RAMP[i + 1];
  const mix = (shift) => {
    const av = (a >> shift) & 0xff;
    const bv = (b >> shift) & 0xff;
    return Math.round(av + (bv - av) * f);
  };
  return [mix(16), mix(8), mix(0)];
}

/**
 * Render a depth.u16 buffer into `canvas`.
 * Returns { near, far, fill } in metres / fraction, for the legend.
 */
export function drawDepth(canvas, buffer, w, h) {
  const raw = new Uint16Array(buffer);
  if (raw.length < w * h) return null;

  let near = Infinity;
  let far = -Infinity;
  let valid = 0;
  for (let i = 0; i < w * h; i++) {
    const mm = raw[i];
    /* zero is ARKit's "no reading", not a surface at the lens */
    if (mm > 50 && mm < 20000) {
      valid++;
      if (mm < near) near = mm;
      if (mm > far) far = mm;
    }
  }
  if (!valid) return { near: 0, far: 0, fill: 0 };

  const span = far - near || 1;
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext('2d');
  const img = ctx.createImageData(w, h);

  for (let i = 0; i < w * h; i++) {
    const mm = raw[i];
    const o = i * 4;
    if (mm <= 50 || mm >= 20000) {
      /* no reading: near-black, so it does not read as "very close" */
      img.data[o] = 12; img.data[o + 1] = 14; img.data[o + 2] = 18;
      img.data[o + 3] = 255;
      continue;
    }
    const [r, g, b] = rampAt((mm - near) / span);
    img.data[o] = r; img.data[o + 1] = g; img.data[o + 2] = b;
    img.data[o + 3] = 255;
  }

  ctx.putImageData(img, 0, 0);
  ctx.imageSmoothingEnabled = false;

  return { near: near / 1000, far: far / 1000, fill: valid / (w * h) };
}

export function rampCss() {
  return `linear-gradient(90deg, ${RAMP
    .map((c) => `#${c.toString(16).padStart(6, '0')}`).join(',')})`;
}
