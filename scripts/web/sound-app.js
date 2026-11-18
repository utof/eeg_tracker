// sound.html glue: signal source (recorder or demo) -> Session -> targets -> engine (which glides on the
// audio thread), plus the display. The mixer only mirrors the glide for the words on screen.
import { Session } from './sound-session.js';
import { mapState } from './sound-mapping.js';
import { createMixer } from './sound-mixer.js';
import { DemoSignal } from './sound-demo.js';
import { AmbientEngine } from './sound-engine.js';

const $ = (id) => document.getElementById(id);
const RATE_MS = 250;   // analysis 4 times a second on the last 1 s
const MIX_MS = 200;   // display mirror only; the sound itself glides on the audio thread

let run = null;
// for automated checks: every analysis step and every bell
const log = (window.__sound = { steps: [], bells: [], cues: [] });

async function liveAvailable() {
  try { const r = await fetch('state', { cache: 'no-store' }); return r.ok && Array.isArray((await r.json()).data); }
  catch { return false; }
}

async function frame(t) {
  if (run.demo) {
    const phase = run.session.phase, chosen = $('eyes').value;
    run.demo.eyes = chosen || (phase === 'cal-open' ? 'open' : phase === 'cal-closed' ? 'closed' : null);
    return run.demo.frame(t);
  }
  try {
    const s = await (await fetch('state', { cache: 'no-store' })).json();
    return { fs: s.fs, names: s.names, data: s.data, contact: s.contact, age: s.age };
  } catch { return null; }
}

function mark(text) { if (run && !run.demo) fetch('marker', { method: 'POST', body: 'sound: ' + text }).catch(() => {}); }

function soundWords(v, r) {
  if (r.targets.neutral) return r.phase.startsWith('cal') ? 'Neutral sound while calibrating.' : 'Neutral sound: not following the brain right now.';
  const parts = v.calm > 0.7 ? 'Rain soft, drone warm.' : v.calm > 0.3 ? 'Rain easing, drone warming.' : 'Rain up front, drone thin.';
  return v.rough > 0.25 ? parts + ' Roughened by jaw tension.' : parts;
}

function show(r) {
  const v = run.mixer.values;
  $('say').textContent = r.phase === 'cal-open' ? 'Eyes open. Look at one spot. Jaw loose.'
    : r.phase === 'cal-closed' ? 'Eyes closed. Breathe out slowly.' : soundWords(v, r);
  $('why').textContent = r.reason || (r.note ? capital(r.note) : '');
  if (r.alphaX !== null) {
    const cal = r.ref.from === 'calibration';
    $('alpha').textContent = `${r.alphaX.toFixed(1)}× your ${cal ? 'eyes-open level' : 'recent low'}`;
    $('lo').textContent = cal ? 'your eyes-open level' : 'your recent low';
    $('hi').textContent = cal ? 'your eyes-closed level' : 'your recent high';
    $('alphabar').style.width = `${Math.round(100 * Math.min(1, Math.max(0, r.state.alpha ?? 0)))}%`;
  } else { $('alpha').textContent = r.quality === 'learning' ? 'learning…' : '–'; $('alphabar').style.width = '0'; }
  const j = r.state.jaw;
  $('jaw').textContent = j === null ? '–' : j > 0.5 ? 'clenched' : j > 0.05 ? 'tense' : 'relaxed';
  $('bells').textContent = r.bells === 'on' ? `on · ${log.bells.length} rung` : r.bells === 'off' ? 'off' : capital(r.bells);
  $('bells').style.fontSize = r.bells.length > 12 ? '15px' : '';
  const dots = $('contact').querySelectorAll('.dot');
  ['O1', 'O2', 'T3', 'T4'].forEach((n, i) => { dots[i].className = 'dot ' + (r.measures.quality[n] || ''); });
  $('base').textContent = r.phase.startsWith('cal') ? 'calibrating' : r.ref ? `from ${r.ref.from}` : 'learning';
}
const capital = (s) => s.charAt(0).toUpperCase() + s.slice(1);

async function analyse() {
  if (!run) return;
  const t = (performance.now() - run.t0) / 1000;
  const f = await frame(t);
  if (!run) return;
  const r = run.session.update(f, t);
  run.targets = r.targets;
  run.engine.glide(r.targets, run.mixer.values);
  if (r.cue) {
    run.engine.cue(); log.cues.push({ t, cue: r.cue });
    mark(r.cue === 'close-eyes' ? 'calibration eyes closed' : 'calibration done, ' + run.session.note);
  }
  if (r.ring) { run.engine.bell(); log.bells.push({ t, demo: run.demo ? { eyes: run.demo.closed(t), jaw: run.demo.jaw(t) } : null }); mark('bell'); }
  log.steps.push({ t, quality: r.quality, calm: r.targets.calm, rough: r.targets.rough, jaw: r.state.jaw, bellsAllowed: r.targets.bellsAllowed });
  if (log.steps.length > 20000) log.steps.shift();
  show(r);
  run.timer = setTimeout(analyse, Math.max(0, RATE_MS - ((performance.now() - run.t0) / 1000 - t) * 1000));
}

async function start(calibrate) {
  if (run) return;
  const demo = $('src').value === 'demo';
  const engine = new AmbientEngine();
  await engine.start();
  log.audio = engine.ctx.state;
  const neutral = mapState({ alpha: null, jaw: null, quality: 'none' });
  run = { demo: demo ? new DemoSignal(Date.now() & 0xffff) : null, engine, session: new Session(),
    mixer: createMixer(neutral), targets: neutral, t0: performance.now(), last: performance.now() };
  run.session.begin(0, calibrate); log.t0wall = Date.now();
  mark(calibrate ? 'start, calibration eyes open' : 'start without calibration');
  engine.glide(neutral, run.mixer.values);
  run.mix = setInterval(() => {
    const now = performance.now();
    run.mixer.step(run.targets, (now - run.last) / 1000); run.last = now;
  }, MIX_MS);
  $('go').disabled = $('go2').disabled = $('src').disabled = true; $('stop').disabled = false;
  analyse();
}

async function stop() {
  if (!run) return;
  const r = run; mark('stop'); run = null;
  clearTimeout(r.timer); clearInterval(r.mix);
  $('say').textContent = 'Stopped.'; $('why').textContent = '';
  $('stop').disabled = true;
  await r.engine.stop();
  $('go').disabled = $('go2').disabled = $('src').disabled = false;
}

$('go').onclick = () => start(true);
$('go2').onclick = () => start(false);
$('stop').onclick = stop;
$('clench').onclick = () => { if (run?.demo) run.demo.jawUntil = run.demo.t + 3; };
$('src').onchange = () => { $('demo').style.display = $('src').value === 'demo' ? 'flex' : 'none'; };

const want = new URLSearchParams(location.search).get('src');
liveAvailable().then((ok) => {
  $('src').value = want === 'demo' || want === 'live' ? want : ok ? 'live' : 'demo';
  if (!ok && $('src').value === 'demo') $('why').textContent = 'No recorder found, so the demo signal is selected.';
  $('src').onchange();
});
