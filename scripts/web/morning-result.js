// One morning check-in result (<start>.morning.json from scripts/morning_check.py) as plain HTML, for morning.html
// (right after saving) and sleep.html (under the sleep periods). Values come from the result's `back` and `ratings`;
// the comparison with earlier mornings is the result's `compared` rows, worded like morning_check.py's printout, so
// the laptop and the pages say the same. Results made before `compared` existed simply show no comparison.
//
// Port note: the phone app reads the same JSON; only the row list and the wording below need porting.

const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
export const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ESC[c]);

const num = (d) => (v) => v.toFixed(d);
export const ROWS = [
  ['back.alpha_ec_uv2', 'Alpha strength, eyes closed', (v) => `${v.toFixed(1)} µV²`],
  ['back.ec_rise', 'Eyes-closed rise (closed / open)', (v) => `${v.toFixed(1)}×`],
  ['back.iaf_hz', 'Alpha speed', (v) => `${v.toFixed(2)} Hz`],
  ['back.aperiodic_slope_ec', '1/f slope, eyes closed', num(2)],
  ['back.clean_share', 'Clean data', (v) => `${Math.round(v * 100)} %`],
  ['ratings.kss', 'Sleepiness', (v) => `${v} of 9`],
  ['ratings.mood', 'Mood', (v) => `${v} of 5`],
  ['ratings.tension', 'Tension', (v) => `${v} of 5`],
];
const NOTE = 'One morning means little; look at the trend over weeks. Lower alpha speed than usual often goes with ' +
  'sleepiness. These are your own numbers, not norms.';
const CSS = `
.mr-row{display:grid;grid-template-columns:1fr auto;gap:2px 12px;padding:8px 0;border-top:1px solid #24282c}
.mr-row b{font-weight:600;font-variant-numeric:tabular-nums;text-align:right}
.mr-row small{grid-column:1/-1;color:#9aa0a6;font-size:14px}
.mr-row small.above,.mr-row small.below{color:#e6c35c}`;

const get = (r, path) => path.split('.').reduce((o, k) => (o && typeof o === 'object' ? o[k] : undefined), r);
const finite = (v) => typeof v === 'number' && Number.isFinite(v);

/** Adds the rows' style to the page once (pages call morningHtml after the DOM exists). */
function style() {
  if (typeof document === 'undefined' || document.getElementById('mr-css')) return;
  const s = document.createElement('style');
  s.id = 'mr-css'; s.textContent = CSS;
  document.head.appendChild(s);
}

/** Rows of [label, value text, comparison text, where] for one result. */
export function morningRows(r) {
  const cmp = Object.fromEntries((Array.isArray(r?.compared) ? r.compared : []).map((c) => [c.key, c]));
  return ROWS.map(([key, label, fmt]) => {
    const v = get(r, key);
    const text = finite(v) ? fmt(v) : key.startsWith('back.') ? 'not enough clean data' : 'not rated';
    const c = cmp[key];
    return [label, text, finite(v) && c && c.comparison ? String(c.comparison) : '', c?.where ?? ''];
  });
}

/** The result as HTML (all text escaped); a heading with the check-in's date and time unless `title` is false. */
export function morningHtml(r, { title = true } = {}) {
  style();
  if (!r || typeof r !== 'object' || !r.back) return '';
  const when = String(r.start ?? '');
  const date = /^\d{4}-\d{2}-\d{2}/.test(when)
    ? new Date(`${when.slice(0, 10)}T12:00:00`).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' })
    : '';
  let html = title ? `<h2>Morning check-in${date ? `, ${esc(date)} ${esc(when.slice(11, 16))}` : ''}</h2>` : '';
  const rows = morningRows(r);
  if (Array.isArray(r.compared) && r.compared.every((c) => !c.earlier)) {
    html += '<p class="muted">First check-in: nothing to compare with yet.</p>';
  }
  html += rows.map(([label, text, cmp, where]) =>
    `<div class="mr-row"><span>${esc(label)}</span><b>${esc(text)}</b>` +
    `${cmp ? `<small class="${esc(where)}">${esc(cmp)}</small>` : ''}</div>`).join('');
  if (finite(get(r, 'back.alpha_ec_uv2')) && !finite(get(r, 'back.iaf_hz'))) {
    html += '<p class="muted">No clear alpha peak with eyes closed today (contact, or an alert / tense start can do this).</p>';
  }
  return `${html}<p class="muted">${esc(NOTE)}</p>`;
}
