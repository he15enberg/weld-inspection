/* Inline SVG charts. No library.
 *
 * Form was chosen per measure before any colour was picked:
 *
 *   verdict split      -> stat tiles, not a pie. Three numbers with a status
 *                         meaning; a 3-slice donut of close values is harder to
 *                         read than the numbers themselves.
 *   captures per day   -> stacked bars. Composition over time, 3 series, so a
 *                         legend is mandatory and segments get a 2px surface gap.
 *   defects by class   -> ranked horizontal bars in ONE colour. Colouring each
 *                         bar by its class would double-encode length as hue and
 *                         burn the only free channel on what the axis already
 *                         says. The class swatch sits beside the label instead,
 *                         where it does useful work: matching the colour the
 *                         reader saw on the overlay photograph.
 *   framing vs verdict -> horizontal bars in the status colours, because here
 *                         the categories ARE the verdicts.
 *
 * Every chart carries a hover tooltip, thin marks, 4px rounded data-ends
 * anchored to the baseline, and a recessive grid.
 */

const NS = 'http://www.w3.org/2000/svg';

const CSS = (name) =>
  getComputedStyle(document.documentElement).getPropertyValue(name).trim();

const VERDICTS = ['approve', 'rework', 'reject'];

function verdictColour(v) {
  return { approve: CSS('--good'), rework: CSS('--warn'), reject: CSS('--bad') }[v]
    || CSS('--text-faint');
}

/* A shape as well as a colour, so a verdict never depends on hue alone. */
const VERDICT_GLYPH = { approve: '✓', rework: '⟳', reject: '✕' };

const el = (tag, attrs = {}) => {
  const node = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  return node;
};

const fmt = (n) => (n == null ? '—' : (+n).toLocaleString());
const pct = (n) => (n == null ? '—' : `${(n * 100).toFixed(n < 0.1 ? 1 : 0)}%`);

/* ------------------------------------------------------------- tooltip */

let tip;

function showTip(html, evt) {
  if (!tip) {
    tip = document.createElement('div');
    tip.className = 'tip';
    document.body.appendChild(tip);
  }
  tip.innerHTML = html;
  tip.style.display = 'block';
  const pad = 14;
  const box = tip.getBoundingClientRect();
  let x = evt.clientX + pad;
  let y = evt.clientY - box.height - pad;
  if (x + box.width > innerWidth - 8) x = evt.clientX - box.width - pad;
  if (y < 8) y = evt.clientY + pad;
  tip.style.left = `${x}px`;
  tip.style.top = `${y}px`;
}

const hideTip = () => { if (tip) tip.style.display = 'none'; };

function hoverable(node, html) {
  node.addEventListener('mousemove', (e) => showTip(html, e));
  node.addEventListener('mouseleave', hideTip);
}

function empty(host, message) {
  host.innerHTML = `<p class="empty">${message}</p>`;
}

/* ---------------------------------------------------- captures per day */

export function perDay(host, rows, legendHost) {
  host.innerHTML = '';
  if (!rows || !rows.length) {
    empty(host, 'No captures yet.');
    if (legendHost) legendHost.innerHTML = '';
    return;
  }

  const W = host.clientWidth || 560;
  const H = 210;
  const pad = { t: 12, r: 8, b: 28, l: 34 };
  const iw = W - pad.l - pad.r;
  const ih = H - pad.t - pad.b;

  const data = rows.map((r) => ({
    day: r.day,
    reject: r.rejects || 0,
    rework: r.reworks || 0,
    approve: Math.max((r.n || 0) - (r.rejects || 0) - (r.reworks || 0), 0),
    total: r.n || 0,
  }));

  const max = Math.max(...data.map((d) => d.total), 1);
  const step = iw / data.length;
  const bw = Math.min(step * 0.62, 42);

  const svg = el('svg', { viewBox: `0 0 ${W} ${H}`, height: H });

  /* recessive grid: three lines, behind everything */
  for (let i = 0; i <= 2; i++) {
    const value = i === 0 ? 0 : (i === 1 ? Math.floor(max / 2) : max);
    const y = pad.t + ih - (value / max) * ih;
    svg.appendChild(el('line', {
      x1: pad.l, x2: W - pad.r, y1: y, y2: y,
      stroke: CSS('--border'), 'stroke-width': 1,
    }));
    const label = el('text', {
      x: pad.l - 7, y: y + 4, 'text-anchor': 'end',
      fill: CSS('--text-faint'), 'font-size': 10,
    });
    label.textContent = value;
    svg.appendChild(label);
  }

  data.forEach((d, i) => {
    const x = pad.l + i * step + (step - bw) / 2;
    let y = pad.t + ih;

    /* stacked from the baseline up, worst on top so it is never cropped */
    for (const key of ['approve', 'rework', 'reject']) {
      const value = d[key];
      if (!value) continue;
      const h = (value / max) * ih;
      y -= h;
      const bar = el('rect', {
        x, y, width: bw,
        /* 2px surface gap between segments, so adjacent fills never touch */
        height: Math.max(h - 2, 1),
        rx: 4, fill: verdictColour(key),
      });
      svg.appendChild(bar);
    }

    /* one hit target per day, larger than the bar */
    const hit = el('rect', {
      x: pad.l + i * step, y: pad.t, width: step, height: ih,
      fill: 'transparent',
    });
    hoverable(hit, `<strong>${d.day}</strong><br>` + VERDICTS
      .map((v) => `<span class="r"><i style="background:${verdictColour(v)}"></i>`
        + `${VERDICT_GLYPH[v]} ${v} ${d[v]}</span>`).join('')
      + `<span class="r" style="color:var(--text-faint)">total ${d.total}</span>`);
    svg.appendChild(hit);

    /* label every day when there is room, else the ends and the middle */
    const showAll = data.length <= 10;
    if (showAll || i === 0 || i === data.length - 1 || i === (data.length >> 1)) {
      const t = el('text', {
        x: pad.l + i * step + step / 2, y: H - 9,
        'text-anchor': 'middle', fill: CSS('--text-faint'), 'font-size': 10,
      });
      t.textContent = d.day.slice(5);
      svg.appendChild(t);
    }
  });

  host.appendChild(svg);

  if (legendHost) {
    legendHost.innerHTML = VERDICTS.map((v) =>
      `<span><i style="background:${verdictColour(v)}"></i>`
      + `${VERDICT_GLYPH[v]} ${v}</span>`).join('');
  }
}

/* ---------------------------------------------------- defects by class */

/* Matches overlay.py, so a swatch here is the colour on the photograph. Used
   only as a legend marker beside the label -- never as the bar fill. */
/* The LIGHT steps of the class palette -- same eight hues as
 * weldz-server/overlay.py, stepped for a light surface rather than a
 * photograph. overlay.py carries the rationale; the short version is that no
 * eight-hue set survives colour blindness all-pairs, so the palette is
 * arranged so every confusable pair leads to the same verdict, and the four
 * classes that appear on every frame were validated as a set.
 *
 * Note `undercut` (#EDA100) measures 2.11:1 against the light surface, under
 * the 3:1 bar -- which is why the class name is always printed beside its
 * swatch here and the table view exists. Colour never carries a class alone. */
const CLASS_COLOUR = {
  crack: '#E34948',          // red    -- reject
  discontinuity: '#EB6834',  // orange -- reject
  undercut: '#EDA100',       // amber  -- rework
  porosity: '#008300',       // green  -- acceptable
  spatter: '#1BAF7A',        // aqua   -- acceptable
  overlap: '#4A3AA7',        // violet -- acceptable
  weld_seam: '#2A78D6',      // blue   -- structure
  workpiece: '#D62D8C',      // pink   -- structure
};

export function byClass(host, rows) {
  host.innerHTML = '';
  if (!rows || !rows.length) return empty(host, 'No defects detected yet.');

  const data = [...rows].sort((a, b) => b.n - a.n);
  const max = Math.max(...data.map((d) => d.n), 1);

  const rowH = 30;
  const W = host.clientWidth || 560;
  const labelW = 108;
  const valueW = 66;
  const iw = W - labelW - valueW;
  const H = data.length * rowH + 6;

  const svg = el('svg', { viewBox: `0 0 ${W} ${H}`, height: H });

  data.forEach((d, i) => {
    const y = i * rowH + 3;
    const w = Math.max((d.n / max) * iw, 2);

    const swatch = el('rect', {
      x: 0, y: y + 8, width: 9, height: 9, rx: 2,
      fill: CLASS_COLOUR[d.label] || CSS('--text-faint'),
    });
    svg.appendChild(swatch);

    const name = el('text', {
      x: 15, y: y + 16, fill: CSS('--text-dim'), 'font-size': 11.5,
      'dominant-baseline': 'middle',
    });
    name.textContent = d.label.replace(/_/g, ' ');
    svg.appendChild(name);

    /* track, then the bar: one hue for every bar (single series) */
    svg.appendChild(el('rect', {
      x: labelW, y: y + 5, width: iw, height: 14, rx: 4,
      fill: CSS('--surface-high'),
    }));
    svg.appendChild(el('rect', {
      x: labelW, y: y + 5, width: w, height: 14, rx: 4, fill: CSS('--blue'),
    }));

    /* direct value labels: few enough rows that every one is legible */
    const value = el('text', {
      x: labelW + iw + 8, y: y + 16, fill: CSS('--text'),
      'font-size': 11.5, 'font-weight': 600,
      style: 'font-variant-numeric: tabular-nums',
    });
    value.textContent = d.n;
    svg.appendChild(value);

    const hit = el('rect', {
      x: 0, y, width: W, height: rowH, fill: 'transparent',
    });
    hoverable(hit,
      `<strong>${d.label.replace(/_/g, ' ')}</strong><br>`
      + `${d.n} detected<br>`
      + `avg ${d.avg_mm ?? '—'} mm · largest ${d.max_mm ?? '—'} mm`);
    svg.appendChild(hit);
  });

  host.appendChild(svg);
}

/* ------------------------------------------------- framing vs verdict */

export function framing(host, rows) {
  host.innerHTML = '';
  const data = (rows || []).filter((r) => r.avg_coverage != null);
  if (!data.length) {
    return empty(host,
      'Not enough captures with a workpiece mask to compare framing yet.');
  }

  const order = VERDICTS.filter((v) => data.some((d) => d.verdict === v));
  const byVerdict = Object.fromEntries(data.map((d) => [d.verdict, d]));
  const max = Math.max(...data.map((d) => d.avg_coverage), 0.05);

  const rowH = 38;
  const W = host.clientWidth || 900;
  const labelW = 96;
  const valueW = 108;
  const iw = W - labelW - valueW;
  const H = order.length * rowH + 6;

  const svg = el('svg', { viewBox: `0 0 ${W} ${H}`, height: H });

  order.forEach((v, i) => {
    const d = byVerdict[v];
    const y = i * rowH + 4;
    const w = Math.max((d.avg_coverage / max) * iw, 2);

    const name = el('text', {
      x: 0, y: y + 18, fill: CSS('--text-dim'), 'font-size': 12,
      'dominant-baseline': 'middle',
    });
    name.textContent = `${VERDICT_GLYPH[v]} ${v}`;
    svg.appendChild(name);

    svg.appendChild(el('rect', {
      x: labelW, y: y + 7, width: iw, height: 18, rx: 4,
      fill: CSS('--surface-high'),
    }));
    svg.appendChild(el('rect', {
      x: labelW, y: y + 7, width: w, height: 18, rx: 4, fill: verdictColour(v),
    }));

    const value = el('text', {
      x: labelW + iw + 10, y: y + 18, fill: CSS('--text'),
      'font-size': 12, 'font-weight': 600,
      style: 'font-variant-numeric: tabular-nums',
    });
    value.textContent = `${pct(d.avg_coverage)} of frame`;
    svg.appendChild(value);

    const hit = el('rect', { x: 0, y, width: W, height: rowH, fill: 'transparent' });
    hoverable(hit,
      `<strong>${VERDICT_GLYPH[v]} ${v}</strong><br>`
      + `${d.n} capture${d.n === 1 ? '' : 's'}<br>`
      + `workpiece fills ${pct(d.avg_coverage)} of the frame on average`);
    svg.appendChild(hit);
  });

  host.appendChild(svg);
}


/* ---------------------------------------------- small multiples, per verdict */

/* The stacked bar shows composition well and trend badly: only the bottom
 * segment sits on a baseline, so rework and reject are hard to follow across
 * days. Three panels on ONE shared scale fix that. The alternative -- a second
 * y-axis -- would invent a correlation that is not in the data. */
export function multiples(host, rows) {
  host.innerHTML = '';
  if (!rows || !rows.length) return empty(host, 'No captures yet.');

  const data = rows.map((r) => ({
    day: r.day,
    reject: r.rejects || 0,
    rework: r.reworks || 0,
    approve: Math.max((r.n || 0) - (r.rejects || 0) - (r.reworks || 0), 0),
  }));
  /* one scale across all three panels, or they are not comparable */
  const max = Math.max(1, ...data.flatMap((d) => VERDICTS.map((v) => d[v])));

  for (const v of VERDICTS) {
    const panel = document.createElement('div');
    const total = data.reduce((a, d) => a + d[v], 0);
    panel.innerHTML = '<div class="sm-title">'
      + '<i style="background:' + verdictColour(v) + '"></i>'
      + VERDICT_GLYPH[v] + ' ' + v + '<b>' + total + '</b></div>';

    const W = 300;
    const H = 92;
    const pad = { t: 6, r: 2, b: 14, l: 2 };
    const ih = H - pad.t - pad.b;
    const step = (W - pad.l - pad.r) / data.length;
    const bw = Math.min(step * 0.66, 20);

    const svg = el('svg', {
      viewBox: '0 0 ' + W + ' ' + H, height: H, preserveAspectRatio: 'none',
    });

    /* one baseline only: the panels are read against each other, so extra
       rules would be noise */
    svg.appendChild(el('line', {
      x1: pad.l, x2: W - pad.r, y1: pad.t + ih, y2: pad.t + ih,
      stroke: CSS('--border'), 'stroke-width': 1,
    }));

    data.forEach((d, i) => {
      const value = d[v];
      const h = (value / max) * ih;
      const x = pad.l + i * step + (step - bw) / 2;
      if (value) {
        svg.appendChild(el('rect', {
          x, y: pad.t + ih - h, width: bw, height: Math.max(h, 2),
          rx: 3, fill: verdictColour(v),
        }));
      }
      const hit = el('rect', {
        x: pad.l + i * step, y: 0, width: step, height: H, fill: 'transparent',
      });
      hoverable(hit, '<strong>' + d.day + '</strong><br>'
        + '<span class="r"><i style="background:' + verdictColour(v) + '"></i>'
        + value + ' ' + v + '</span>');
      svg.appendChild(hit);
    });

    /* first and last day only -- three panels of dates would be unreadable */
    [[0, 'start'], [data.length - 1, 'end']].forEach((pair) => {
      const i = pair[0];
      const t = el('text', {
        x: i === 0 ? pad.l : W - pad.r, y: H - 3,
        'text-anchor': pair[1], fill: CSS('--text-faint'), 'font-size': 9,
      });
      t.textContent = data[i].day.slice(5);
      svg.appendChild(t);
    });

    panel.appendChild(svg);
    host.appendChild(panel);
  }
}

/* ------------------------------------------------------------- reject rate */

export function rejectRate(host, rows) {
  host.innerHTML = '';
  const data = (rows || []).filter((r) => r.n);
  if (data.length < 2) {
    return empty(host, 'Two days of captures are needed for a trend.');
  }

  const pts = data.map((r) => ({
    day: r.day, n: r.n, rejects: r.rejects || 0,
    rate: (r.rejects || 0) / r.n,
  }));
  const mean = pts.reduce((a, p) => a + p.rejects, 0)
    / pts.reduce((a, p) => a + p.n, 0);

  /* A rate computed from one or two captures is noise: a single reject on a
     quiet day reads as 100% and drags the axis flat. Those days are still
     plotted -- hiding them would be worse -- but they are drawn hollow and the
     axis is scaled on the days that carry weight. */
  const THIN = 3;
  const solid = pts.filter((p) => p.n >= THIN);
  const scaleOn = solid.length ? solid : pts;
  const top = Math.min(
    Math.max(Math.max.apply(null, scaleOn.map((p) => p.rate)), mean) * 1.3
    || 0.1, 1);

  const W = host.clientWidth || 520;
  const H = 180;
  const pad = { t: 10, r: 14, b: 24, l: 38 };
  const iw = W - pad.l - pad.r;
  const ih = H - pad.t - pad.b;
  const X = (i) => pad.l + (i / (pts.length - 1)) * iw;
  const Y = (rate) => pad.t + ih - (rate / top) * ih;

  const svg = el('svg', { viewBox: '0 0 ' + W + ' ' + H, height: H });

  for (let i = 0; i <= 2; i++) {
    const value = (top / 2) * i;
    const y = Y(value);
    svg.appendChild(el('line', {
      x1: pad.l, x2: W - pad.r, y1: y, y2: y,
      stroke: CSS('--border'), 'stroke-width': 1,
    }));
    const t = el('text', {
      x: pad.l - 7, y: y + 4, 'text-anchor': 'end',
      fill: CSS('--text-faint'), 'font-size': 10,
    });
    t.textContent = Math.round(value * 100) + '%';
    svg.appendChild(t);
  }

  /* the period average, as the reference the daily line is read against */
  const my = Y(mean);
  svg.appendChild(el('line', {
    x1: pad.l, x2: W - pad.r, y1: my, y2: my,
    stroke: CSS('--text-faint'), 'stroke-width': 1, 'stroke-dasharray': '4 4',
  }));
  const avg = el('text', {
    x: W - pad.r, y: my - 6, 'text-anchor': 'end',
    fill: CSS('--text-faint'), 'font-size': 9.5,
  });
  avg.textContent = 'average ' + Math.round(mean * 100) + '%';
  svg.appendChild(avg);

  svg.appendChild(el('polyline', {
    points: pts.map((p, i) => X(i) + ',' + Y(Math.min(p.rate, top))).join(' '),
    fill: 'none', stroke: CSS('--bad'), 'stroke-width': 2,
    'stroke-linejoin': 'round', 'stroke-linecap': 'round',
  }));

  pts.forEach((p, i) => {
    const thin = p.n < THIN;
    /* a 2px surface ring, so overlapping markers stay countable */
    svg.appendChild(el('circle', {
      cx: X(i), cy: Y(Math.min(p.rate, top)), r: 4,
      fill: thin ? CSS('--surface') : CSS('--bad'),
      stroke: thin ? CSS('--bad') : CSS('--surface'), 'stroke-width': 2,
    }));
    const hit = el('circle', {
      cx: X(i), cy: Y(Math.min(p.rate, top)), r: 13, fill: 'transparent',
    });
    hoverable(hit, '<strong>' + p.day + '</strong><br>'
      + Math.round(p.rate * 100) + '% rejected<br>'
      + p.rejects + ' of ' + p.n + ' captures'
      + (thin ? '<br><span style="color:var(--text-faint)">too few to trust'
        + '</span>' : ''));
    svg.appendChild(hit);
  });

  [[0, 'start'], [pts.length - 1, 'end']].forEach((pair) => {
    const t = el('text', {
      x: X(pair[0]), y: H - 7, 'text-anchor': pair[1],
      fill: CSS('--text-faint'), 'font-size': 10,
    });
    t.textContent = pts[pair[0]].day.slice(5);
    svg.appendChild(t);
  });

  host.appendChild(svg);
}

/* ---------------------------------------------------------- size per class */

export function sizeRanges(host, sizes) {
  host.innerHTML = '';
  const data = Object.keys(sizes || {})
    .map((label) => Object.assign({ label }, sizes[label]))
    .sort((a, b) => b.p50 - a.p50);
  if (!data.length) return empty(host, 'No measured defects yet.');

  const max = Math.max(1, ...data.map((d) => d.p95));
  const rowH = 32;
  const W = host.clientWidth || 520;
  const labelW = 108;
  const valueW = 74;
  const iw = W - labelW - valueW;
  const H = data.length * rowH + 6;
  const X = (mm) => labelW + (mm / max) * iw;

  const svg = el('svg', { viewBox: '0 0 ' + W + ' ' + H, height: H });

  data.forEach((d, i) => {
    const y = i * rowH + 3;
    const mid = y + 16;

    svg.appendChild(el('rect', {
      x: 0, y: y + 11, width: 9, height: 9, rx: 2,
      fill: CLASS_COLOUR[d.label] || CSS('--text-faint'),
    }));
    const name = el('text', {
      x: 15, y: mid, fill: CSS('--text-dim'), 'font-size': 11.5,
      'dominant-baseline': 'middle',
    });
    name.textContent = d.label.replace(/_/g, ' ');
    svg.appendChild(name);

    /* the range as a soft bar, the median as a mark on it */
    svg.appendChild(el('rect', {
      x: X(d.min), y: mid - 4, width: Math.max(X(d.p95) - X(d.min), 2),
      height: 8, rx: 4, fill: CSS('--blue'), opacity: 0.32,
    }));
    svg.appendChild(el('rect', {
      x: X(d.p50) - 1.5, y: mid - 9, width: 3, height: 18, rx: 1.5,
      fill: CSS('--blue'),
    }));

    const value = el('text', {
      x: W - 2, y: mid, 'text-anchor': 'end', fill: CSS('--text'),
      'font-size': 11.5, 'font-weight': 600, 'dominant-baseline': 'middle',
      style: 'font-variant-numeric: tabular-nums',
    });
    value.textContent = d.p50.toFixed(1) + ' mm';
    svg.appendChild(value);

    const hit = el('rect', {
      x: 0, y, width: W, height: rowH, fill: 'transparent',
    });
    hoverable(hit, '<strong>' + d.label.replace(/_/g, ' ') + '</strong><br>'
      + 'median ' + d.p50.toFixed(1) + ' mm · 95th ' + d.p95.toFixed(1) + ' mm<br>'
      + 'range ' + d.min.toFixed(1) + '–' + d.max.toFixed(1)
      + ' mm over ' + d.n + ' detections');
    svg.appendChild(hit);
  });

  host.appendChild(svg);
}

/* ---------------------------------------------------------------- histogram */

export function histogram(host, buckets, opts) {
  opts = opts || {};
  host.innerHTML = '';
  const list = buckets || [];
  const total = list.reduce((a, b) => a + b, 0);
  if (!total) return empty(host, opts.emptyText || 'Nothing recorded yet.');

  const W = host.clientWidth || 520;
  const H = opts.height || 150;
  const pad = { t: 12, r: 6, b: 22, l: 34 };
  const iw = W - pad.l - pad.r;
  const ih = H - pad.t - pad.b;
  const max = Math.max(1, ...list);
  const step = iw / list.length;
  const bw = Math.max(step - 3, 2);

  const svg = el('svg', { viewBox: '0 0 ' + W + ' ' + H, height: H });
  svg.appendChild(el('line', {
    x1: pad.l, x2: W - pad.r, y1: pad.t + ih, y2: pad.t + ih,
    stroke: CSS('--border'), 'stroke-width': 1,
  }));
  const topLabel = el('text', {
    x: pad.l - 7, y: pad.t + 4, 'text-anchor': 'end',
    fill: CSS('--text-faint'), 'font-size': 10,
  });
  topLabel.textContent = max;
  svg.appendChild(topLabel);

  list.forEach((n, i) => {
    const h = (n / max) * ih;
    if (n) {
      svg.appendChild(el('rect', {
        x: pad.l + i * step + 1.5, y: pad.t + ih - h,
        width: bw, height: Math.max(h, 2), rx: 3,
        /* one hue for every bar: the axis already carries the category, so a
           ramp would double-encode height as colour */
        fill: opts.colour || CSS('--blue'),
      }));
    }
    const hit = el('rect', {
      x: pad.l + i * step, y: 0, width: step, height: H, fill: 'transparent',
    });
    hoverable(hit, '<strong>' + (opts.label ? opts.label(i) : i) + '</strong><br>'
      + n + ' (' + Math.round((n / total) * 100) + '%)');
    svg.appendChild(hit);
  });

  (opts.ticks || [0, list.length - 1]).forEach((i) => {
    const t = el('text', {
      x: pad.l + i * step + step / 2, y: H - 6, 'text-anchor': 'middle',
      fill: CSS('--text-faint'), 'font-size': 9.5,
    });
    t.textContent = opts.tick ? opts.tick(i) : i;
    svg.appendChild(t);
  });

  host.appendChild(svg);
}

export { verdictColour, VERDICT_GLYPH, CLASS_COLOUR, fmt, pct, hideTip };
