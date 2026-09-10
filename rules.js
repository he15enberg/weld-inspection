/* The rule editor, and the utilisation bar used on a capture.
 *
 * Two things this deliberately does NOT do.
 *
 * It does not let you type a metric. The server publishes the list of
 * quantities it knows how to compute and the editor offers only those -- an
 * editor that accepted an expression would be a remote code execution endpoint
 * with a nice UI.
 *
 * It does not save and re-score in one action. Overwriting an archive of
 * verdicts is not something to do by accident, so "Preview impact" runs the
 * re-score as a dry run and shows what would move before anything is written.
 */

const esc = (s) => String(s ?? '').replace(/[&<>"]/g,
  (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

/* A rule's limit reads in whatever unit its metric is in. Fractions are shown
   as percentages because nobody thinks about porosity in 0.02. */
const PERCENT = new Set(['defect_area_fraction', 'seam_continuity']);
const toUI = (m, v) => (PERCENT.has(m) ? +(v * 100).toFixed(2) : v);
const fromUI = (m, v) => (PERCENT.has(m) ? v / 100 : v);

let doc = null;         // the ruleset as last loaded or edited
let meta = null;        // metrics / comparators / outcomes, from the server
let dirty = false;

export function utilisationBar(u) {
  /* One rule's standing, as a bar. Utilisation is normalised so 1.0 always
     means "at the limit" whichever way the comparator points -- otherwise a
     `>=` rule would render backwards and read as passing when it is not. */
  if (!u) return '';
  if (u.utilisation == null) {
    return `<div class="util util-none">
        <div class="util-head"><b>${esc(u.name)}</b><span>not measurable</span></div>
        <div class="util-track"></div>
        <small>${esc(u.detail || '')}</small>
      </div>`;
  }
  const pct = Math.min(u.utilisation * 100, 140);
  const state = u.status === 'breached' ? 'bad' : (pct > 80 ? 'warn' : 'ok');
  return `<div class="util util-${state}">
      <div class="util-head">
        <b>${esc(u.name)}</b>
        <span>${Math.round(u.utilisation * 100)}% of limit</span>
      </div>
      <div class="util-track"><i style="width:${pct.toFixed(1)}%"></i></div>
      <small>${esc(u.detail || '')}</small>
    </div>`;
}

function ruleCard(r, i) {
  const info = meta.metrics[r.metric] || { label: r.metric, unit: '', help: '' };
  const needsSeam = (meta.needs_seam || []).includes(r.metric);
  const opt = (list, cur) => list.map((v) =>
    `<option value="${esc(v)}"${v === cur ? ' selected' : ''}>${esc(v)}</option>`).join('');

  return `<div class="rule${r.enabled ? '' : ' is-off'}" data-i="${i}">
    <div class="rule-head">
      <label class="tick">
        <input type="checkbox" data-f="enabled"${r.enabled ? ' checked' : ''}>
        <b>${esc(r.name)}</b>
      </label>
      <span class="rule-id">${esc(r.id)}</span>
    </div>
    <p class="rule-help">
      ${esc(info.help)}
      ${needsSeam ? '<em> Needs a measurable weld seam; without one this rule '
        + 'reports indeterminate rather than passing.</em>' : ''}
    </p>
    <div class="rule-grid">
      <label>Compare
        <select data-f="comparator">${opt(meta.comparators, r.comparator)}</select>
      </label>
      <label><span>Limit <small>${esc(info.unit)}</small></span>
        <input type="number" step="any" data-f="limit"
               value="${toUI(r.metric, r.limit)}">
      </label>
      <label class="${r.comparator === 'between' ? '' : 'hide'}">Upper
        <input type="number" step="any" data-f="limit_max"
               value="${r.limit_max == null ? '' : toUI(r.metric, r.limit_max)}">
      </label>
      <label>Weight
        <input type="number" step="1" min="0" data-f="weight" value="${r.weight}">
      </label>
      <label>On breach
        <select data-f="on_breach">${opt(meta.outcomes, r.on_breach)}</select>
      </label>
    </div>
  </div>`;
}

function render() {
  document.getElementById('rulesVersion').textContent =
    `version ${doc.version}${doc.saved ? ` · saved ${doc.saved.replace('T', ' ')}` : ''}`
    + (dirty ? ' · unsaved changes' : '');
  document.getElementById('rulesList').innerHTML =
    doc.rules.map(ruleCard).join('');
  document.getElementById('bands').innerHTML = `
    <label>Rework at or above
      <input type="number" step="any" data-band="rework_at" value="${doc.bands.rework_at}">
    </label>
    <label>Reject at or above
      <input type="number" step="any" data-band="reject_at" value="${doc.bands.reject_at}">
    </label>
    <p class="band-note">
      Reject must sit above rework. The server checks this too and refuses the
      save rather than storing a set that can never return a rework.
    </p>`;
  document.getElementById('rulesSave').disabled = !dirty;
}

function mark() {
  dirty = true;
  document.getElementById('rulesSave').disabled = false;
  document.getElementById('rulesVersion').textContent =
    `version ${doc.version} · unsaved changes`;
}

function readField(el) {
  const card = el.closest('.rule');
  const rule = doc.rules[+card.dataset.i];
  const f = el.dataset.f;
  if (f === 'enabled') {
    rule.enabled = el.checked;
    card.classList.toggle('is-off', !rule.enabled);
  } else if (f === 'limit' || f === 'limit_max') {
    const raw = parseFloat(el.value);
    if (Number.isNaN(raw)) return;
    rule[f] = fromUI(rule.metric, raw);
  } else if (f === 'weight') {
    rule.weight = parseFloat(el.value) || 0;
  } else {
    rule[f] = el.value;
    if (f === 'comparator') render();     // the upper bound appears or hides
  }
  mark();
}

function error(msg) {
  const box = document.getElementById('rulesError');
  box.hidden = !msg;
  box.textContent = msg || '';
}

async function api(path, opts) {
  const res = await fetch(path, opts);
  if (!res.ok) {
    let detail = `${res.status}`;
    try { detail = (await res.json()).detail || detail; } catch { /* not JSON */ }
    throw new Error(detail);
  }
  return res.json();
}

async function loadRules() {
  error('');
  const data = await api('rules');
  meta = data;
  doc = { version: data.version, saved: data.saved, rules: data.rules,
          bands: data.bands, weights: data.weights };
  dirty = false;
  render();
}

async function saveRules() {
  error('');
  try {
    const stored = await api('rules', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ rules: doc.rules, bands: doc.bands,
                             weights: doc.weights }),
    });
    doc.version = stored.version;
    doc.saved = stored.saved;
    dirty = false;
    render();
    /* Saving changes how FUTURE captures are judged. It does not touch the
       archive -- that needs an explicit re-score, and saying so here stops the
       charts looking wrong for a reason nobody can find. */
    showRescore({ note: `Saved as version ${stored.version}. Captures already `
      + `recorded keep the verdict they were given — use Preview impact, then `
      + `Apply, to re-judge them.` });
  } catch (e) {
    error(`Could not save: ${e.message}`);
  }
}

async function preview(apply = false) {
  error('');
  const box = document.getElementById('rescore');
  box.hidden = false;
  box.innerHTML = '<p class="muted">Working…</p>';
  try {
    const r = await api(`rescore?dry_run=${apply ? 'false' : 'true'}`,
                        { method: 'POST' });
    showRescore(r);
  } catch (e) {
    box.innerHTML = `<p class="bad">Re-score failed: ${esc(e.message)}</p>`;
  }
}

function showRescore(r) {
  const box = document.getElementById('rescore');
  box.hidden = false;
  if (r.note) {
    box.innerHTML = `<p class="muted">${esc(r.note)}</p>`;
    return;
  }
  const moves = Object.entries(r.moves || {});
  box.innerHTML = `
    <h2>${r.dry_run ? 'If applied' : 'Applied'}</h2>
    <p class="muted">
      ${r.changed} of ${r.examined} captures change verdict under version
      ${r.ruleset_version}${r.errors ? ` · ${r.errors} could not be read` : ''}.
    </p>
    ${moves.length ? `<ul class="moves">${moves.map(([k, n]) =>
      `<li><b>${n}</b> ${esc(k)}</li>`).join('')}</ul>` : ''}
    ${(r.sample || []).length ? `<div class="rows">${r.sample.map((c) =>
      `<a class="row" href="#/capture/${encodeURIComponent(c.id)}">
         <div class="row-main"><strong>${esc(c.from)} → ${esc(c.to)}</strong>
         <small>${esc(c.headline)}</small></div>
         <span class="count">score ${c.score}</span>
       </a>`).join('')}</div>` : ''}
    ${r.dry_run && r.changed ? '<button class="primary" id="rescoreApply">'
      + 'Apply to the archive</button>' : ''}`;
  const apply = document.getElementById('rescoreApply');
  if (apply) apply.addEventListener('click', () => preview(true));
}

export function initRules() {
  const list = document.getElementById('rulesList');
  /* Delegated, and on `input` as well as `change`: a number typed into a field
     that is never blurred would otherwise be silently dropped on save. */
  list.addEventListener('input', (e) => {
    if (e.target.dataset.f) readField(e.target);
  });
  list.addEventListener('change', (e) => {
    if (e.target.dataset.f) readField(e.target);
  });
  document.getElementById('bands').addEventListener('input', (e) => {
    const b = e.target.dataset.band;
    if (!b) return;
    const v = parseFloat(e.target.value);
    if (!Number.isNaN(v)) { doc.bands[b] = v; mark(); }
  });
  document.getElementById('rulesSave').addEventListener('click', saveRules);
  document.getElementById('rulesReload').addEventListener('click', loadRules);
  document.getElementById('rulesPreview').addEventListener('click', () => preview(false));
  return loadRules;
}
