// sound.html glue (a stopgap until the phone app): a source (the recorder's /stream, or the demo) ->
// the core (sound-session.js) -> the engine, which glides on the audio thread, plus the display.
// All decisions live in the pure modules; this file only wires them to the page.
import { Session } from './sound-session.js';
import { mapState } from './sound-mapping.js';
import { createMixer, MIX_TIMES } from './sound-mixer.js';
import { DemoSignal } from './sound-demo.js';
import { LiveSource, DemoSource } from './sound-source.js';
import { AmbientEngine, isPhone } from './sound-engine.js';

const $ = (id) => document.getElementById(id);
const MIX_MS = 200;   // display mirror and the "no data" check; the sound itself glides on the audio thread

let run = null, lastSession = null;
// for automated checks: analysis steps, bells, cues, and the session log (window.__sound.session())
const log = (window.__sound = { steps: [], bells: [], cues: [], lags: [], session: () => (run ? run.session : lastSession)?.log.toJSON() });

async function liveAvailable() {
  try { const r = await fetch('state', { cache: 'no-store' }); return r.ok && Array.isArray((await r.json()).data); }
  catch { return false; }
}

function mark(text) { if (run && !run.demo) fetch('marker', { method: 'POST', body: ('sound: ' + text).slice(0, 200) }).catch(() => {}); }

// what the sources call (sound-source.js)
const sink = {
  rows(rows, batch) {
    if (!run) return;
    run.lastData = performance.now();
    if (batch) {
      if (log.firstI === undefined) log.firstI = batch.i;   // stream index of the session's first sample
      log.lags.push(Date.now() - batch.t * 1000); if (log.lags.length > 600) log.lags.shift();
    }
    handle(run.session.push(rows));
  },
  gap() { if (run) run.session.gap(); },
  contact(c) { if (run) run.session.contact(c); },
  status(text) { if (run) $('why').textContent = text; },
};

function handle(steps) {
  if (!run || !steps.length) return;
  for (const r of steps) {
    if (r.cue) {
      run.engine.cue(); log.cues.push({ t: r.t, cue: r.cue });
      mark(r.cue === 'close-eyes' ? 'calibration eyes closed' : 'calibration done, ' + r.note);
    }
    if (r.ring) { run.engine.bell(); log.bells.push({ t: r.t, n: r.n }); mark('bell'); }
    if (r.blockEnd) {
      const b = r.blockEnd;
      mark(`block ${b.block}: above the line ${Math.round(100 * (b.share ?? 0))}% of ${Math.round(b.counted)} s counted, line ${['lowered', 'kept', 'raised'][b.moved + 1]}`);
    }
    log.steps.push({ t: r.t, n: r.n, quality: r.quality, veto: r.veto, z: r.z, calm: r.targets.calm, rough: r.targets.rough,
      jaw: r.jaw, bellsAllowed: r.targets.bellsAllowed });
    if (log.steps.length > 20000) log.steps.shift();
  }
  const last = steps[steps.length - 1];
  if (run.demo) {   // the demo's eyes follow the calibration cues unless chosen
    const chosen = $('eyes').value, phase = last.phase;
    run.demo.eyes = chosen === 'drowsy' ? 'closed' : chosen || (phase === 'cal-open' ? 'open' : phase === 'cal-closed' ? 'closed' : null);
    run.demo.alphaHz = chosen === 'drowsy' ? 7.5 : 10;
  }
  run.engine.bed(!last.silent);
  run.targets = last.targets;
  run.engine.glide(last.targets, run.mixer.values);
  show(last);
}

function soundWords(v, r) {
  if (r.silent) return 'Quiet while calibrating.';
  if (r.veto === 'drowsy') return 'A little brighter: drifting off? Stay awake.';
  if (r.targets.neutral) return 'Neutral sound: not following the brain right now.';
  const parts = v.calm > 0.7 ? 'Rain soft, drone warm.' : v.calm > 0.3 ? 'Rain easing, drone warming.' : 'Rain up front, drone thin.';
  return v.rough > 0.25 ? parts + ' Roughened by jaw tension.' : parts;
}

function show(r) {
  const v = run.mixer.values;
  $('say').textContent = r.phase === 'cal-open' ? 'Eyes open. Look at one spot. Jaw loose.'
    : r.phase === 'cal-closed' ? 'Eyes closed. Breathe out slowly.' : r.phase === 'learn' ? 'Close your eyes and settle.' : soundWords(v, r);
  $('why').textContent = r.reason || (r.note ? capital(r.note) : '');
  if (r.z !== null) {
    $('alpha').textContent = `${r.alphaX.toFixed(1)}× your line`;
    $('alphabar').style.width = `${Math.round(100 * Math.min(1, Math.max(0, (r.z + 2) / 4)))}%`;
  } else { $('alpha').textContent = r.quality === 'learning' ? 'learning…' : '–'; $('alphabar').style.width = '0'; }
  const j = r.jaw;
  $('jaw').textContent = j === null ? '–' : j > 0.5 ? 'clenched' : j > 0.05 ? 'tense' : 'relaxed';
  $('bells').textContent = r.bells === 'on' ? `on · ${r.rung} rung` : capital(r.bells);
  $('bells').style.fontSize = r.bells.length > 12 ? '15px' : '';
  const dots = $('contact').querySelectorAll('.dot');
  ['O1', 'O2', 'T3', 'T4'].forEach((n, i) => { dots[i].className = 'dot ' + (r.channels[n] || ''); });
  $('base').textContent = r.phase.startsWith('cal') ? 'calibrating' : r.phase === 'learn' ? 'learning' : `block ${r.block} (3 min each)`;
}
const capital = (s) => s.charAt(0).toUpperCase() + s.slice(1);

async function start(calibrate) {
  if (run) return;
  const demo = $('src').value === 'demo', mode = $('mode').value;
  const engine = new AmbientEngine({ light: isPhone(), mode });
  await engine.start();
  log.audio = engine.ctx.state; log.firstI = undefined; log.lags = [];
  const session = new Session({ mode, calibrate }), neutral = mapState({ z: null, jaw: null, quality: 'none', veto: null });
  run = { demo: demo ? new DemoSignal(Date.now() & 0xffff) : null, engine, session, mixer: createMixer(neutral, MIX_TIMES[mode]),
    targets: neutral, last: performance.now(), lastData: performance.now() };
  run.source = demo ? new DemoSource(run.demo) : new LiveSource();
  session.log.note({ started: new Date().toISOString(), source: run.source.kind, phone: isPhone(), audio: engine.latency() });
  watchAudio(engine);
  mark(`start ${mode}, ${calibrate ? 'calibration eyes open' : 'without calibration'}; audio ${engine.hint}`);
  engine.bed(!calibrate);
  engine.glide(neutral, run.mixer.values);
  run.mix = setInterval(() => {
    const now = performance.now(), quiet = (now - run.lastData) / 1000;
    if (quiet > 2) {   // nothing from the source: neutral bed, and say why
      run.targets = mapState({ z: null, jaw: null, quality: 'none', veto: null });
      run.engine.glide(run.targets, run.mixer.values);
      $('why').textContent = `No data from the headband for ${Math.round(quiet)} s`;
    }
    run.mixer.step(run.targets, (now - run.last) / 1000); run.last = now;
  }, MIX_MS);
  $('go').disabled = $('go2').disabled = $('src').disabled = $('mode').disabled = true; $('stop').disabled = false;
  await run.source.start(sink);
}

async function stop() {
  if (!run) return;
  const r = run, a = r.audio, s = r.session;
  const lat = r.engine.latency(), ms = (x) => (x === null ? '?' : Math.round(x * 1000));
  s.log.note({ stopped: new Date().toISOString(), audio: lat, dropouts: a.behind, dropoutMs: Math.round(a.behindMs), pauses: a.pauses,
    streamLagMs: median(log.lags) });
  mark(`stop; ${s.rung} bells; audio ${lat.hint} ${ms(lat.base)}+${ms(lat.output)} ms, fell behind ${a.behind}x (${Math.round(a.behindMs)} ms), paused ${a.pauses}x, light ${r.engine.light}`);
  run = null; lastSession = s;
  r.source.stop(); clearInterval(r.mix); clearInterval(a.timer);
  $('say').textContent = 'Stopped.'; $('why').textContent = '';
  $('stop').disabled = true;
  await r.engine.stop();
  $('go').disabled = $('go2').disabled = $('src').disabled = $('mode').disabled = false;
}
const median = (a) => (a.length ? [...a].sort((x, y) => x - y)[a.length >> 1] : null);

// Dropouts: the phone's audio system pairs its own clock with the wall clock (getOutputTimestamp).
// When the sound misses its deadline, the audio clock falls behind the wall clock; each jump of
// over 20 ms counts as one dropout. A browser that pauses the audio (screen off, battery saver)
// is resumed at once and counted.
function watchAudio(engine) {
  const ctx = engine.ctx, a = (run.audio = { behind: 0, behindMs: 0, pauses: 0, lag: null });
  ctx.onstatechange = () => {
    if (!run || run.engine !== engine || ctx.state === 'running' || ctx.state === 'closed') return;
    a.pauses++; mark(`audio ${ctx.state} by the browser; resuming`); ctx.resume().catch(() => {});
  };
  a.timer = setInterval(() => {
    if (!run || run.engine !== engine || ctx.state !== 'running') { a.lag = null; return; }
    const ts = ctx.getOutputTimestamp ? ctx.getOutputTimestamp() : null;
    if (ts && ts.performanceTime > 0) {
      const lag = ts.performanceTime / 1000 - ts.contextTime;
      if (a.lag !== null && lag - a.lag > 0.02) { a.behind++; a.behindMs += (lag - a.lag) * 1000; }
      a.lag = lag;
    }
    $('snd').textContent = (engine.light ? 'light · ' : '') + (a.behind ? `${a.behind} dropouts (${Math.round(a.behindMs)} ms)` : 'no dropouts')
      + (a.pauses ? ` · paused ${a.pauses}×` : '');
  }, 1000);
}
document.addEventListener('visibilitychange', () => {
  const ctx = run?.engine?.ctx;
  if (ctx && ctx.state !== 'running' && ctx.state !== 'closed') ctx.resume().catch(() => {});
});

$('go').onclick = () => start(true);
$('go2').onclick = () => start(false);
$('stop').onclick = stop;
$('clench').onclick = () => { if (run?.demo) run.demo.jawUntil = run.demo.t + 3; };
$('src').onchange = () => { $('demo').style.display = $('src').value === 'demo' ? 'flex' : 'none'; };

const want = new URLSearchParams(location.search);
if (want.get('mode') === 'relax') $('mode').value = 'relax';
liveAvailable().then((ok) => {
  const src = want.get('src');
  $('src').value = src === 'demo' || src === 'live' ? src : ok ? 'live' : 'demo';
  if (!ok && $('src').value === 'demo') $('why').textContent = 'No recorder found, so the demo signal is selected.';
  $('src').onchange();
});
