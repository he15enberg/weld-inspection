/* Wiring: fetch, render, navigate.
 *
 * Served by the same FastAPI that runs inference, so there is no CORS, no build
 * step and no second process to keep alive. The API is relative to the page.
 *
 * The token, when the server is running with one, is read from `?t=` once and
 * kept in sessionStorage -- so a shared link works and the value does not sit
 * in the URL bar for the rest of the session.
 */

import {
  perDay, byClass, framing, multiples, rejectRate, sizeRanges, histogram,
  verdictColour, VERDICT_GLYPH, CLASS_COLOUR, pct,
} from './charts.js';
import { initRules, utilisationBar } from './rules.js';
import { drawDepth, rampCss } from './depth.js';
import { mountCloud } from './cloud.js';

const PAGE = 24;

const state = { view: 'overview', offset: 0, total: 0, filters: {} };

/* ------------------------------------------------------------------ api */

const url = new URL(location.href);
if (url.searchParams.get('t')) {
  sessionStorage.setItem('weldz.token', url.searchParams.get('t'));
  url.searchParams.delete('t');
  history.replaceState(null, '', url);
}
const TOKEN = sessionStorage.getItem('weldz.token') || '';

const headers = TOKEN ? { 'X-Weldz-Token': TOKEN } : {};

async function api(path) {
  const res = await fetch(path, { headers });
  if (res.status === 401) {
    throw new Error('The server needs a token. Open this page with ?t=YOUR_TOKEN');
  }
  if (!res.ok) throw new Error(`${path} returned ${res.status}`);
  return res.json();
}

function fileUrl(id, name) {
  return TOKEN
    ? `captures/${id}/file/${name}?t=${encodeURIComponent(TOKEN)}`
    : `captures/${id}/file/${name}`;
}

function toast(message) {
  const node = document.getElementById('toast');
  node.textContent = message;
  node.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { node.hidden = true; }, 5000);
}

const esc = (s) => String(s ?? '').replace(/[<>&"]/g,
  (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' }[c]));

const when = (iso) => {
  if (!iso) return '—';
  const d = new Date(iso);
  const today = new Date().toDateString() === d.toDateString();
  const time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  return today ? `Today ${time}`
    : `${d.toLocaleDateString([], { day: 'numeric', month: 'short' })} ${time}`;
};

const pill = (v) => `<span class="pill" style="color:${verdictColour(v)};`
  + `background:${verdictColour(v)}22;border:1px solid ${verdictColour(v)}66">`
  + `<i>${VERDICT_GLYPH[v] || ''}</i>${esc(v)}</span>`;

/* --------------------------------------------------------------- chrome */

/* The sidebar and the demo banner describe the whole store, not the overview,
 * so they are filled from the boot /stats call as well -- otherwise a deep
 * link to #/captures shows a sidebar full of em-dashes. */
function chrome(s) {
  const set = (id, text) => { document.getElementById(id).textContent = text; };

  /* short enough not to wrap in a 218px sidebar */
  set('brandSub', s.enabled
    ? `${s.total ?? 0} captures · ${pct(s.reject_rate)} reject`
    : 'storage off');
  set('sideModel', s.total
    ? `${s.by_class?.length || 0} defect classes seen` : 'no captures');
  set('sideStore', s.enabled ? `${s.total ?? 0} captures` : 'off');
  set('sideVlm', s.total ? 'see a capture' : '—');

  /* No synthetic-data banner. `stats.demo` still counts the seeded rows and
     every one of them still carries `"demo": true` in its own result.json, so
     the distinction survives in the data even though the dashboard no longer
     announces it. `seed_from_capture.py --wipe-demo` clears them. */
}

/* ------------------------------------------------------------- overview */

async function loadOverview() {
  let s;
  try {
    s = await api('stats');
  } catch (e) {
    toast(e.message);
    return;
  }

  if (!s.enabled) {
    document.getElementById('tiles').innerHTML =
      '<div class="tile"><div class="k">storage off</div>'
      + '<b>—</b><small>set WELDZ_CAPTURES on the server</small></div>';
    return;
  }
  if (s.error) toast(`Index unavailable — run store.rebuild(). (${s.error})`);

  const v = s.verdicts || {};
  const tile = (k, value, sub, colour) =>
    `<div class="tile"><div class="k">`
    + (colour ? `<span class="dot" style="background:${colour}"></span>` : '')
    + `${k}</div><b>${value}</b><small>${sub}</small></div>`;

  /* The reject rate is the headline number, so it gets a tile of its own
     rather than being left for the reader to divide out. */
  document.getElementById('tiles').innerHTML = [
    tile('captures', s.total ?? 0,
      s.timing?.avg_ms ? `${Math.round(s.timing.avg_ms)} ms average` : 'all time'),
    tile('approve', v.approve ?? 0, pct((v.approve || 0) / (s.total || 1)),
      verdictColour('approve')),
    tile('rework', v.rework ?? 0, pct(s.rework_rate), verdictColour('rework')),
    tile('reject', v.reject ?? 0, pct(s.reject_rate), verdictColour('reject')),
  ].join('');

  perDay(document.getElementById('perday'), s.per_day,
    document.getElementById('perdayLegend'));
  multiples(document.getElementById('multiples'), s.per_day);
  rejectRate(document.getElementById('rate'), s.per_day);
  histogram(document.getElementById('hours'), s.hours, {
    height: 180,
    emptyText: 'No captures yet.',
    label: (h) => `${String(h).padStart(2, '0')}:00`,
    ticks: [0, 6, 12, 18, 23],
    tick: (h) => `${String(h).padStart(2, '0')}`,
  });

  byClass(document.getElementById('classes'), s.by_class);
  sizeRanges(document.getElementById('sizes'), s.sizes);
  framing(document.getElementById('framing'), s.framing);
  histogram(document.getElementById('depthHist'), s.depth_hist, {
    height: 170,
    emptyText: 'No measured detections yet.',
    label: (i) => `${i * 10}–${i * 10 + 10}% of the mask`,
    ticks: [0, 5, 9],
    tick: (i) => `${i * 10}%`,
  });

  chrome(s);

  /* A table view always exists, so identity is never colour-alone and the
     numbers are available to anyone the charts do not serve. */
  const rows = (list, cols) => `<table><thead><tr>`
    + cols.map((c) => `<th${c[2] ? ' class="num"' : ''}>${c[0]}</th>`).join('')
    + `</tr></thead><tbody>` + list.map((r) => '<tr>'
      + cols.map((c) => `<td${c[2] ? ' class="num"' : ''}>${c[1](r)}</td>`).join('')
      + '</tr>').join('') + '</tbody></table>';

  document.getElementById('statsTable').innerHTML =
    '<h3>Per day</h3>'
    + rows(s.per_day || [], [
      ['Day', (r) => esc(r.day)],
      ['Captures', (r) => r.n, 1],
      ['Rework', (r) => r.reworks || 0, 1],
      ['Reject', (r) => r.rejects || 0, 1],
    ])
    + '<h3>By class</h3>'
    + rows(s.by_class || [], [
      ['Class', (r) => `<span class="swatch" style="background:`
        + `${CLASS_COLOUR[r.label] || '#888'}"></span> ${esc(r.label)}`],
      ['Detected', (r) => r.n, 1],
      ['Average mm', (r) => r.avg_mm ?? '—', 1],
      ['Largest mm', (r) => r.max_mm ?? '—', 1],
    ])
    + '<h3>Framing</h3>'
    + rows(s.framing || [], [
      ['Verdict', (r) => esc(r.verdict)],
      ['Captures', (r) => r.n, 1],
      ['Frame share', (r) => pct(r.avg_coverage), 1],
    ]);
}

/* ------------------------------------------------------------- captures */

async function loadCaptures() {
  const q = new URLSearchParams({ limit: PAGE, offset: state.offset });
  for (const [k, v] of Object.entries(state.filters)) if (v) q.set(k, v);

  let data;
  try {
    data = await api(`captures?${q}`);
  } catch (e) {
    toast(e.message);
    return;
  }
  state.total = data.total || 0;

  const host = document.getElementById('rows');
  if (!data.captures.length) {
    host.innerHTML = '<p class="empty">No captures match these filters.</p>';
  } else {
    host.innerHTML = data.captures.map((c) => {
      const worst = c.worst_label
        ? `worst ${esc(c.worst_label)}`
          + (c.worst_mm ? ` ${c.worst_mm.toFixed(1)} mm` : '')
        : 'no defects';
      return `<div class="row" data-id="${esc(c.id)}">
        <img loading="lazy" src="${fileUrl(c.id, 'overlay.jpg')}" alt="">
        <div>
          <div class="who">${esc(c.headline || worst)}</div>
          <div class="sub">${when(c.ts)} · ${c.n_detections || 0} regions · ${worst}
            ${c.device ? ` · ${esc(c.device)}` : ''}</div>
          ${c.assess_summary
            ? `<div class="note">${esc(c.assess_summary)}</div>` : ''}
        </div>
        ${pill(c.verdict)}
      </div>`;
    }).join('');

    host.querySelectorAll('.row').forEach((row) =>
      row.addEventListener('click', () => {
        history.replaceState(null, '', `#/capture/${row.dataset.id}`);
        openCapture(row.dataset.id);
      }));
  }

  document.getElementById('fCount').textContent =
    `${state.total} capture${state.total === 1 ? '' : 's'}`;
  const pages = Math.max(Math.ceil(state.total / PAGE), 1);
  const page = Math.floor(state.offset / PAGE) + 1;
  document.getElementById('page').textContent = `${page} of ${pages}`;
  document.getElementById('prev').disabled = state.offset === 0;
  document.getElementById('next').disabled = state.offset + PAGE >= state.total;
}

/* --------------------------------------------------------------- detail */

async function openCapture(id) {
  const sheet = document.getElementById('sheet');
  const body = document.getElementById('sheetBody');
  document.getElementById('sheetId').textContent = id;
  body.innerHTML = '<p class="empty">Loading…</p>';
  sheet.hidden = false;
  document.body.style.overflow = 'hidden';

  let rec;
  try {
    rec = await api(`captures/${encodeURIComponent(id)}`);
  } catch (e) {
    body.innerHTML = `<p class="empty">${esc(e.message)}</p>`;
    return;
  }

  const j = rec.judgement || {};
  const a = rec.assessment || {};
  const colour = verdictColour(j.verdict);
  const fired = (j.checks || []).filter((c) => c.status !== 'clear');
  const clear = (j.checks || []).filter((c) => c.status === 'clear');

  const dets = (rec.detections || []).slice().sort((x, y) => {
    const s = (d) => (['workpiece', 'weld_seam'].includes(d.label) ? 1 : 0);
    return s(x) - s(y);
  });

  body.innerHTML = `
    <div class="banner" style="border-color:${colour}73;background:${colour}1a">
      <div class="top-row">
        <span style="font-size:20px;color:${colour}">${VERDICT_GLYPH[j.verdict] || ''}</span>
        <h2 style="color:${colour}">${esc((j.verdict || '').toUpperCase())}</h2>
        <span style="margin-left:auto;font-size:11px;color:var(--text-faint)">
          ${when(rec.captured_at)}${rec.device ? ` · ${esc(rec.device)}` : ''}
        </span>
      </div>
      ${j.headline ? `<p>${esc(j.headline)}</p>` : ''}
      ${fired.map((c) => `<div class="rule"><b>${esc(c.id)}</b><span>`
        + `${esc(c.title)} — ${esc(c.detail)}`
        + `${c.reason ? `<br>${esc(c.reason)}` : ''}</span></div>`).join('')}
      ${clear.length
        ? `<div class="rule" style="margin-top:11px"><b></b><span>`
          + `${clear.length} rules clear: `
          + clear.map((c) => esc(c.title)).join(', ') + `</span></div>`
        : ''}
    </div>

    ${(j.utilisations || []).length ? `
      <figure class="card wide">
        <figcaption>
          <h2>Rule utilisation</h2>
          <p>
            How close each tunable rule came to its limit. The marker is the
            limit; a bar past it is a breach.
            ${j.score != null ? `Weighted score ${j.score}`
              + (j.bands ? ` — rework at ${j.bands.rework_at}, reject at `
                + `${j.bands.reject_at}` : '') + '.' : ''}
            ${j.ruleset_version ? `Judged under rule set v${j.ruleset_version}.` : ''}
          </p>
        </figcaption>
        <div class="utils">${(j.utilisations || []).map(utilisationBar).join('')}</div>
      </figure>` : ''}

    ${j.seam && j.seam.status === 'ok' ? `
      <figure class="card wide">
        <figcaption><h2>Seam</h2></figcaption>
        <div class="tiles">
          <div class="tile"><div class="k">length</div>
            <b>${j.seam.length_mm ?? '—'}</b><small>mm</small></div>
          <div class="tile"><div class="k">width</div>
            <b>${j.seam.width_mm ?? '—'}</b><small>mm mean</small></div>
          <div class="tile"><div class="k">continuity</div>
            <b>${j.seam.continuity != null
                 ? Math.round(j.seam.continuity * 100) + '%' : '—'}</b>
            <small>of the joint</small></div>
          <div class="tile"><div class="k">off seam</div>
            <b>${j.off_seam_ignored ?? 0}</b><small>ignored</small></div>
        </div>
      </figure>` : (j.seam && j.seam.status ? `
      <div class="demo-note" style="margin-top:14px">
        <span>&#9888;</span><span>The weld seam could not be measured
        (${esc(j.seam.status)}), so the rules that depend on it report
        indeterminate rather than passing.</span>
      </div>` : '')}

    ${a.status === 'ready' && a.summary ? `
      <div class="assess">
        <div class="hdr">◈ assessment <em>advisory — not the verdict</em></div>
        ${(a.missed_rejectable || []).length ? `<div class="missed">
          Possible ${esc(a.missed_rejectable.join(', '))} the detector did not
          report. The verdict above does not include this.</div>` : ''}
        <p>${esc(a.summary)}</p>
        ${(a.concerns || []).length ? `<div class="chips">`
          + a.concerns.map((c) => `<span>${esc(c)}</span>`).join('')
          + `</div>` : ''}
      </div>` : ''}

    <div class="shots">
      <div class="shot"><h3>Captured frame</h3>
        <div class="frame"><img src="${fileUrl(id, 'color.jpg')}" alt=""></div></div>
      <div class="shot"><h3>Segments</h3>
        <div class="frame"><img src="${fileUrl(id, 'overlay.jpg')}" alt=""></div></div>
      <div class="shot"><h3>LiDAR depth</h3>
        <div class="frame"><canvas id="depthCanvas"
          style="width:100%;image-rendering:pixelated"></canvas></div>
        <div id="depthLegend" style="padding:9px 14px"></div></div>
      <div class="shot wide-shot">
        <h3>Point cloud
          <span class="shot-tools">
            <button class="chip" id="cloudPhoto" data-on="1">Photo</button>
            <button class="chip" id="cloudDepth">Depth</button>
            <span class="chip-gap"></span>
            <button class="chip" id="cloudMask" data-on="1">Part only</button>
            <button class="chip" id="cloudReset">Reset</button>
          </span>
        </h3>
        <div class="frame cloud-frame" id="cloudHost"></div>
        <div id="cloudLegend" style="padding:9px 14px"></div>
      </div>
    </div>

    <details class="card wide data" open style="margin-top:14px">
      <summary>${dets.length} detections</summary>
      <table><thead><tr>
        <th>Class</th><th class="num">Confidence</th><th class="num">Size</th>
        <th class="num">Area</th><th class="num">Distance</th>
        <th class="num">Depth cover</th>
      </tr></thead><tbody>
      ${dets.map((d) => `<tr>
        <td><span class="swatch" style="background:${CLASS_COLOUR[d.label] || '#888'}"></span>
          ${esc(d.label.replace(/_/g, ' '))}</td>
        <td class="num">${Math.round((d.confidence || 0) * 100)}%</td>
        <td class="num">${d.width_mm != null
          ? `${d.width_mm.toFixed(1)} × ${(d.height_mm ?? 0).toFixed(1)} mm`
            + (d.uncertainty_mm != null ? ` ±${d.uncertainty_mm.toFixed(2)}` : '')
          : '<span style="color:var(--text-faint)">no depth</span>'}</td>
        <td class="num">${d.area_mm2 != null ? `${Math.round(d.area_mm2)} mm²` : '—'}</td>
        <td class="num">${d.distance_m != null
          ? `${Math.round(d.distance_m * 1000)} mm` : '—'}</td>
        <td class="num">${d.depth_fill != null ? pct(d.depth_fill) : '—'}</td>
      </tr>`).join('')}
      </tbody></table>
    </details>

    <details class="card wide data" style="margin-top:14px">
      <summary>Provenance — which model produced this</summary>
      <table><tbody>
        ${Object.entries(rec.model || {}).map(([k, v]) =>
          `<tr><th>${esc(k.replace(/_/g, ' '))}</th>`
          + `<td class="num">${esc(v ?? '—')}</td></tr>`).join('')}
        <tr><th>frame</th><td class="num">${rec.image?.width}×${rec.image?.height}</td></tr>
        <tr><th>workpiece share of frame</th><td class="num">${pct(rec.coverage)}</td></tr>
        <tr><th>depth coverage</th><td class="num">${pct(rec.frame_depth_fill)}</td></tr>
        <tr><th>server time</th><td class="num">${rec.timing_ms?.total ?? '—'} ms</td></tr>
      </tbody></table>
    </details>`;

  /* depth is a raw buffer, so it is fetched and painted rather than <img>-ed */
  try {
    const res = await fetch(fileUrl(id, 'depth.u16'), { headers });
    const buf = await res.arrayBuffer();
    const meta = rec.meta || {};
    const stat = drawDepth(document.getElementById('depthCanvas'), buf,
      meta.depth_width || 256, meta.depth_height || 192);
    if (stat) {
      document.getElementById('depthLegend').innerHTML =
        `<div style="display:flex;justify-content:space-between;font-size:10.5px;`
        + `color:var(--text-dim);margin-bottom:5px">`
        + `<span>${Math.round(stat.near * 1000)} mm</span>`
        + `<span>${pct(stat.fill)} coverage</span>`
        + `<span>${Math.round(stat.far * 1000)} mm</span></div>`
        + `<div style="height:6px;border-radius:3px;background:${rampCss()}"></div>`;
    }
  } catch {
    document.getElementById('depthLegend').textContent = 'Depth unavailable.';
  }

  /* The point cloud, from the same depth buffer. Mounted last and guarded --
     it is the one view that can fail on the browser rather than on the data
     (no WebGL2), and a missing cloud must not cost the reader the record. */
  if (_cloud) { _cloud.dispose(); _cloud = null; }
  try {
    _cloud = await mountCloud(
      document.getElementById('cloudHost'), rec, (n) => fileUrl(id, n));
    const legend = document.getElementById('cloudLegend');
    const st = _cloud && _cloud.stats();
    if (st) {
      legend.innerHTML = `<span class="muted">${st.count.toLocaleString()} points`
        + ` · ${Math.round(st.near * 1000)}–${Math.round(st.far * 1000)} mm`
        + ` · drag to orbit, scroll to zoom</span>`;
    } else if (legend) {
      legend.innerHTML = '<span class="muted">No usable depth for a cloud.</span>';
    }
    if (_cloud) {
      const chip = (elId, fn) => {
        const el = document.getElementById(elId);
        if (el) el.addEventListener('click', fn);
        return el;
      };
      const photo = chip('cloudPhoto', () => {
        _cloud.setColour('photo');
        photo.dataset.on = '1';
        delete depth.dataset.on;
      });
      const depth = chip('cloudDepth', () => {
        _cloud.setColour('depth');
        depth.dataset.on = '1';
        delete photo.dataset.on;
      });
      const maskBtn = chip('cloudMask', () => {
        const on = maskBtn.dataset.on === '1';
        _cloud.setMasked(!on);
        if (on) delete maskBtn.dataset.on; else maskBtn.dataset.on = '1';
      });
      chip('cloudReset', () => _cloud.reset());
      // no mask in the record means nothing to crop to, so say so rather than
      // offering a button that does nothing
      if (!_cloud.hasMask() && maskBtn) {
        maskBtn.disabled = true;
        maskBtn.title = 'no workpiece mask in this capture';
        delete maskBtn.dataset.on;
      }
    }
  } catch (e) {
    const legend = document.getElementById('cloudLegend');
    if (legend) legend.innerHTML = `<span class="muted">Cloud unavailable: `
      + `${esc(e.message)}</span>`;
  }
}

/* One viewer at a time: each holds a GL context and a resize listener, and
   leaking them across every opened capture eventually loses the context. */
let _cloud = null;

function closeCapture() {
  if (_cloud) { _cloud.dispose(); _cloud = null; }
  document.getElementById('sheet').hidden = true;
  document.body.style.overflow = '';
}

/* ----------------------------------------------------------------- boot */

function show(view, push = true) {
  state.view = view;
  if (push && location.hash !== `#/${view}`) {
    history.replaceState(null, '', `#/${view}`);
  }
  document.querySelectorAll('.view').forEach((v) =>
    v.classList.toggle('is-on', v.id === view));
  document.querySelectorAll('.nav-item').forEach((t) =>
    t.classList.toggle('is-on', t.dataset.view === view));
  if (view === 'captures') loadCaptures();
  else if (view === 'rules') loadRules();
  else loadOverview();          // overview and quality share one /stats call
}

document.getElementById('nav').addEventListener('click', (e) => {
  /* closest(), not e.target: the nav buttons contain an <svg> icon, so a click
     frequently lands on the child rather than the button. */
  const item = e.target.closest('[data-view]');
  if (item) show(item.dataset.view);
});
document.getElementById('sheetClose').addEventListener('click', () => {
  history.replaceState(null, '', `#/${state.view}`);
  closeCapture();
});
addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !document.getElementById('sheet').hidden) closeCapture();
});

const bind = (id, key) => document.getElementById(id).addEventListener('change', (e) => {
  state.filters[key] = e.target.value;
  state.offset = 0;
  loadCaptures();
});
bind('fVerdict', 'verdict');
bind('fLabel', 'label');
bind('fFrom', 'since');
bind('fTo', 'until');

document.getElementById('fClear').addEventListener('click', () => {
  state.filters = {};
  state.offset = 0;
  ['fVerdict', 'fLabel', 'fFrom', 'fTo'].forEach((id) => {
    document.getElementById(id).value = '';
  });
  loadCaptures();
});
document.getElementById('prev').addEventListener('click', () => {
  state.offset = Math.max(state.offset - PAGE, 0);
  loadCaptures();
});
document.getElementById('next').addEventListener('click', () => {
  state.offset += PAGE;
  loadCaptures();
});

/* the defect filter is populated from what has actually been seen, so it never
   offers a class with no captures behind it */
api('stats').then((s) => {
  chrome(s);
  const select = document.getElementById('fLabel');
  for (const row of s.by_class || []) {
    const option = document.createElement('option');
    option.value = row.label;
    option.textContent = `${row.label} (${row.n})`;
    select.appendChild(option);
  }
}).catch(() => {});

/* charts are sized off clientWidth, so a resize needs a re-render */
let resizeTimer;
addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if (state.view !== 'captures' && state.view !== 'rules') loadOverview();
  }, 180);
});

/* Routes are #/overview, #/captures and #/capture/<id>. The leading slash is
   load-bearing: a bare "#captures" would match <section id="captures"> and the
   browser would anchor-scroll, pushing the filter bar under the sticky header. */
function route() {
  const hash = location.hash.replace(/^#\/?/, '');
  if (hash.startsWith('capture/')) {
    show('captures', false);
    openCapture(hash.slice(8));
    return;
  }
  show(['captures', 'quality', 'rules'].includes(hash) ? hash : 'overview', false);
}

/* Bound once; `initRules` returns the loader so the router can call it
   without the rules module reaching back into the router. */
const loadRules = initRules();

addEventListener('hashchange', route);
route();
