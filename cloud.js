/* The stored depth buffer as a 3D point cloud, in the browser.
 *
 * The app's best view, and the one thing the dashboard could not show. It only
 * needs what is already on disk: `depth.u16`, `confidence.u8`, the intrinsics in
 * `meta`, and the workpiece mask that ships inside `result.json`.
 *
 * Raw WebGL2 and a hand-rolled 4x4 rather than three.js. Two reasons: the
 * dashboard has no build step and no node, and it is served off a laptop during
 * a demo where a CDN fetch is one more thing that can fail. A point cloud needs
 * a projection matrix and gl.POINTS, which is not worth 600 kB of library.
 *
 * The geometry mirrors weldz-mobile/lib/roi.dart exactly, and has to:
 *
 *   - the stored depth is the FULL 256x192 buffer, because the server saves the
 *     upload untouched
 *   - the masks in result.json are sized to the ANALYSED crop, 184x184
 *   - so the depth must be cut to `depth_crop_box_source` before a mask can
 *     index it, or the two are different grids and the part view empties
 *   - fx/fy are unchanged by a crop; only the principal point moves, by the
 *     crop origin
 *
 * The cloud is turned a quarter turn clockwise for the same reason the app does
 * it: ARKit hands over a landscape buffer, every picture is displayed turned to
 * compensate, and a cloud that skipped that read a quarter turn out from
 * everything beside it.
 */

const NEAR_M = 0.05;
const FAR_M = 6.0;
const FOV = 50 * Math.PI / 180;

/* ------------------------------------------------------------------ matrices */

function perspective(fovy, aspect, near, far) {
  const f = 1 / Math.tan(fovy / 2);
  const nf = 1 / (near - far);
  return [f / aspect, 0, 0, 0,
    0, f, 0, 0,
    0, 0, (far + near) * nf, -1,
    0, 0, 2 * far * near * nf, 0];
}

function multiply(a, b) {
  const o = new Array(16).fill(0);
  for (let i = 0; i < 4; i++) {
    for (let j = 0; j < 4; j++) {
      let s = 0;
      for (let k = 0; k < 4; k++) s += a[k * 4 + j] * b[i * 4 + k];
      o[i * 4 + j] = s;
    }
  }
  return o;
}

/** Orbit camera: yaw/pitch around a target, `dist` away. */
function view(yaw, pitch, dist, target) {
  const cp = Math.cos(pitch);
  const eye = [
    target[0] + dist * cp * Math.sin(yaw),
    target[1] + dist * Math.sin(pitch),
    target[2] + dist * cp * Math.cos(yaw),
  ];
  const f = norm([target[0] - eye[0], target[1] - eye[1], target[2] - eye[2]]);
  const up = [0, 1, 0];
  const s = norm(cross(f, up));
  const u = cross(s, f);
  return [s[0], u[0], -f[0], 0,
    s[1], u[1], -f[1], 0,
    s[2], u[2], -f[2], 0,
    -dot(s, eye), -dot(u, eye), dot(f, eye), 1];
}

const cross = (a, b) => [a[1] * b[2] - a[2] * b[1],
  a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
function norm(v) {
  const l = Math.hypot(v[0], v[1], v[2]) || 1;
  return [v[0] / l, v[1] / l, v[2] / l];
}

/* -------------------------------------------------------------------- shaders */

const VERT = `#version 300 es
in vec3 aPos;
in vec3 aCol;
uniform mat4 uMVP;
uniform float uSize;
out vec3 vCol;
void main() {
  gl_Position = uMVP * vec4(aPos, 1.0);
  /* shrink with distance, so the far side of the part does not fur up */
  gl_PointSize = clamp(uSize / max(gl_Position.w, 0.05), 1.0, 14.0);
  vCol = aCol;
}`;

const FRAG = `#version 300 es
precision mediump float;
in vec3 vCol;
out vec4 outColour;
void main() {
  /* round points: discard the corners of the gl_PointCoord square */
  vec2 d = gl_PointCoord - vec2(0.5);
  if (dot(d, d) > 0.25) discard;
  outColour = vec4(vCol, 1.0);
}`;

function compile(gl, type, src) {
  const sh = gl.createShader(type);
  gl.shaderSource(sh, src);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(sh) || 'shader failed');
  }
  return sh;
}

/* ---------------------------------------------------------------------- data */

/** A perceptual-ish near→far ramp. Blue is near, warm is far. */
function ramp(t) {
  const stops = [[0.16, 0.36, 0.72], [0.15, 0.62, 0.75], [0.42, 0.78, 0.55],
    [0.92, 0.80, 0.36], [0.88, 0.44, 0.28]];
  const x = Math.min(Math.max(t, 0), 0.9999) * (stops.length - 1);
  const i = Math.floor(x);
  const f = x - i;
  const a = stops[i];
  const b = stops[i + 1];
  return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f,
    a[2] + (b[2] - a[2]) * f];
}

/** Decode a base64 PNG mask into one byte per sample, at its own size. */
async function decodeMask(b64) {
  const img = new Image();
  img.src = `data:image/png;base64,${b64}`;
  await img.decode();
  const c = document.createElement('canvas');
  c.width = img.width;
  c.height = img.height;
  const ctx = c.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(img, 0, 0);
  const px = ctx.getImageData(0, 0, img.width, img.height).data;
  const out = new Uint8Array(img.width * img.height);
  for (let i = 0; i < out.length; i++) out[i] = px[i * 4] > 127 ? 1 : 0;
  return { data: out, width: img.width, height: img.height };
}

/** The photograph, as sampleable pixels. */
async function decodePhoto(url) {
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    const c = document.createElement('canvas');
    c.width = img.width;
    c.height = img.height;
    const ctx = c.getContext('2d', { willReadFrequently: true });
    ctx.drawImage(img, 0, 0);
    return { px: ctx.getImageData(0, 0, img.width, img.height).data,
      width: img.width, height: img.height };
  } catch {
    return null;              // colour by depth instead; not worth failing over
  }
}

/**
 * Build interleaved positions and colours.
 *
 * `record` is the /captures/{id} document. `mask` is optional and must be the
 * one from the same record, because it is sized to the analysed crop.
 */
function buildPoints(record, depth16, conf, photo, mask, colourMode) {
  const meta = record.meta || {};
  const geo = record.geometry || {};
  const dwFull = meta.depth_width || 256;
  const dhFull = meta.depth_height || 192;

  // Cut the stored full-frame depth down to the analysed crop -- the same
  // rectangle the masks were made against.
  const box = geo.depth_crop_box_source;
  const useCrop = Array.isArray(box) && box.length === 4
    && box[2] <= dwFull && box[3] <= dhFull;
  const ox = useCrop ? box[0] : 0;
  const oy = useCrop ? box[1] : 0;
  const dw = useCrop ? box[2] - box[0] : dwFull;
  const dh = useCrop ? box[3] - box[1] : dhFull;

  // Intrinsics are quoted for the captured image; scale onto the depth grid,
  // then move the principal point by the crop origin. fx/fy are untouched by a
  // crop.
  const sx = dwFull / (meta.image_width || 1920);
  const sy = dhFull / (meta.image_height || 1440);
  const fx = (meta.fx || 1400) * sx;
  const fy = (meta.fy || meta.fx || 1400) * sy;
  const cx = (meta.cx || 960) * sx - ox;
  const cy = (meta.cy || 720) * sy - oy;

  // colour window: the crop of the photo that matches the depth crop
  const cbox = geo.crop_box_source;
  const hasCbox = Array.isArray(cbox) && cbox.length === 4;
  const colX = hasCbox ? cbox[0] : 0;
  const colY = hasCbox ? cbox[1] : 0;
  const colW = hasCbox ? cbox[2] - cbox[0] : (meta.image_width || 1920);
  const colH = hasCbox ? cbox[3] - cbox[1] : (meta.image_height || 1440);

  const maskOk = mask && mask.width === dw && mask.height === dh;

  let zMin = Infinity;
  let zMax = -Infinity;
  for (let v = 0; v < dh; v++) {
    for (let u = 0; u < dw; u++) {
      const z = depth16[(oy + v) * dwFull + (ox + u)] / 1000;
      if (z > NEAR_M && z < FAR_M) {
        if (z < zMin) zMin = z;
        if (z > zMax) zMax = z;
      }
    }
  }
  if (!Number.isFinite(zMin)) return null;
  const span = Math.max(zMax - zMin, 1e-6);

  const pos = [];
  const col = [];
  let cxSum = 0;
  let cySum = 0;
  let czSum = 0;
  let xMin = Infinity; let xMax = -Infinity;
  let yMin = Infinity; let yMax = -Infinity;

  for (let v = 0; v < dh; v++) {
    for (let u = 0; u < dw; u++) {
      const i = (oy + v) * dwFull + (ox + u);
      const z = depth16[i] / 1000;
      if (!(z > NEAR_M && z < FAR_M)) continue;
      if (conf && conf[i] === 0) continue;          // ARKit "low" confidence
      if (maskOk && mask.data[v * dw + u] === 0) continue;

      // quarter turn clockwise, matching the app: (x, y) -> (-y, x)
      const X = -((v - cy) / fy) * z;
      const Y = ((u - cx) / fx) * z;
      pos.push(X, Y, z);
      cxSum += X; cySum += Y; czSum += z;
      if (X < xMin) xMin = X;
      if (X > xMax) xMax = X;
      if (Y < yMin) yMin = Y;
      if (Y > yMax) yMax = Y;

      if (colourMode === 'photo' && photo) {
        const px = Math.round(colX + (u / dw) * colW) / (meta.image_width || 1920) * photo.width;
        const py = Math.round(colY + (v / dh) * colH) / (meta.image_height || 1440) * photo.height;
        const o = ((Math.min(Math.max(py | 0, 0), photo.height - 1)) * photo.width
          + Math.min(Math.max(px | 0, 0), photo.width - 1)) * 4;
        col.push(photo.px[o] / 255, photo.px[o + 1] / 255, photo.px[o + 2] / 255);
      } else {
        const c = ramp((z - zMin) / span);
        col.push(c[0], c[1], c[2]);
      }
    }
  }

  const n = pos.length / 3;
  if (!n) return null;
  return {
    pos: new Float32Array(pos),
    col: new Float32Array(col),
    count: n,
    centre: [cxSum / n, cySum / n, czSum / n],
    near: zMin,
    far: zMax,
    // How big the thing IS, not how far away it is. Framing off `far` puts the
    // camera 289 mm back for a part 115 mm across, which renders it as a
    // thumbnail in the middle of an empty canvas.
    radius: Math.max((xMax - xMin) / 2, (yMax - yMin) / 2,
                     (zMax - zMin) / 2, 0.01),
  };
}

/* -------------------------------------------------------------------- public */

/**
 * Mount a cloud viewer into `host`.
 *
 * Returns { setColour, setMasked, dispose } so the caller owns the controls and
 * this file owns none of the chrome.
 */
export async function mountCloud(host, record, fileUrl) {
  host.innerHTML = '';
  const canvas = document.createElement('canvas');
  canvas.className = 'cloud-canvas';
  host.appendChild(canvas);

  const gl = canvas.getContext('webgl2', { antialias: true, alpha: false });
  if (!gl) {
    host.innerHTML = '<div class="empty">This browser has no WebGL2.</div>';
    return null;
  }

  const [depthBuf, confBuf, photo] = await Promise.all([
    fetch(fileUrl('depth.u16')).then((r) => r.arrayBuffer()),
    fetch(fileUrl('confidence.u8')).then((r) => r.arrayBuffer()).catch(() => null),
    decodePhoto(fileUrl('color.jpg')),
  ]);
  const depth16 = new Uint16Array(depthBuf);
  const conf = confBuf ? new Uint8Array(confBuf) : null;

  // the workpiece mask, for the part-only view; falls back to the seam
  let mask = null;
  for (const want of ['workpiece', 'weld_seam']) {
    const d = (record.detections || []).find(
      (x) => x.label === want && x.mask_png);
    if (d) { mask = await decodeMask(d.mask_png); break; }
  }

  const program = gl.createProgram();
  gl.attachShader(program, compile(gl, gl.VERTEX_SHADER, VERT));
  gl.attachShader(program, compile(gl, gl.FRAGMENT_SHADER, FRAG));
  gl.linkProgram(program);
  gl.useProgram(program);

  const posBuf = gl.createBuffer();
  const colBuf = gl.createBuffer();
  const aPos = gl.getAttribLocation(program, 'aPos');
  const aCol = gl.getAttribLocation(program, 'aCol');
  const uMVP = gl.getUniformLocation(program, 'uMVP');
  const uSize = gl.getUniformLocation(program, 'uSize');
  gl.enable(gl.DEPTH_TEST);

  let state = { colour: 'photo', masked: true, cloud: null };
  let yaw = 0;
  let pitch = -0.25;
  let dist = 0.55;
  let home = 0.55;          // the framing rebuild() computed, for Reset

  function rebuild() {
    const c = buildPoints(record, depth16, conf, photo,
      state.masked ? mask : null, state.colour);
    state.cloud = c;
    if (!c) return;
    gl.bindBuffer(gl.ARRAY_BUFFER, posBuf);
    gl.bufferData(gl.ARRAY_BUFFER, c.pos, gl.STATIC_DRAW);
    gl.enableVertexAttribArray(aPos);
    gl.vertexAttribPointer(aPos, 3, gl.FLOAT, false, 0, 0);
    gl.bindBuffer(gl.ARRAY_BUFFER, colBuf);
    gl.bufferData(gl.ARRAY_BUFFER, c.col, gl.STATIC_DRAW);
    gl.enableVertexAttribArray(aCol);
    gl.vertexAttribPointer(aCol, 3, gl.FLOAT, false, 0, 0);
    // fit the extent to the vertical field of view, with a little air
    dist = Math.max(c.radius / Math.tan(FOV / 2) * 1.45, 0.05);
    home = dist;
  }

  function draw() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.max(host.clientWidth, 1);
    const h = Math.max(host.clientHeight, 1);
    if (canvas.width !== w * dpr || canvas.height !== h * dpr) {
      canvas.width = w * dpr;
      canvas.height = h * dpr;
    }
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.clearColor(0.043, 0.055, 0.075, 1);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    const c = state.cloud;
    if (!c) return;
    const mvp = multiply(
      perspective(FOV, w / h, 0.005, 20),
      view(yaw, pitch, dist, c.centre));
    gl.uniformMatrix4fv(uMVP, false, new Float32Array(mvp));
    gl.uniform1f(uSize, 2.2 * dpr);
    gl.drawArrays(gl.POINTS, 0, c.count);
  }

  let frame = 0;
  const invalidate = () => {
    if (frame) return;
    frame = requestAnimationFrame(() => { frame = 0; draw(); });
  };

  /* drag to orbit, wheel to zoom -- pointer events so it works on a trackpad
     and a touchscreen without a second code path */
  let dragging = false;
  let lastX = 0;
  let lastY = 0;
  canvas.addEventListener('pointerdown', (e) => {
    dragging = true;
    lastX = e.clientX;
    lastY = e.clientY;
    canvas.setPointerCapture(e.pointerId);
  });
  canvas.addEventListener('pointermove', (e) => {
    if (!dragging) return;
    yaw -= (e.clientX - lastX) * 0.008;
    pitch = Math.min(Math.max(pitch - (e.clientY - lastY) * 0.006, -1.4), 1.4);
    lastX = e.clientX;
    lastY = e.clientY;
    invalidate();
  });
  canvas.addEventListener('pointerup', () => { dragging = false; });
  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    dist = Math.min(Math.max(dist * (1 + Math.sign(e.deltaY) * 0.08), 0.06), 12);
    invalidate();
  }, { passive: false });

  const onResize = () => invalidate();
  window.addEventListener('resize', onResize);

  rebuild();
  draw();

  return {
    stats: () => (state.cloud
      ? { count: state.cloud.count, near: state.cloud.near, far: state.cloud.far }
      : null),
    hasMask: () => !!mask,
    setColour(mode) { state.colour = mode; rebuild(); invalidate(); },
    setMasked(on) { state.masked = on; rebuild(); invalidate(); },
    reset() { yaw = 0; pitch = -0.25; dist = home; invalidate(); },
    dispose() {
      window.removeEventListener('resize', onResize);
      if (frame) cancelAnimationFrame(frame);
    },
  };
}
