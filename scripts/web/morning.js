// Guided morning check-in. Served by scripts/record_night.py; markers go to POST /marker.
import { KSS, MOOD, TENSION, phaseSeconds, morningPlan, marker, validRatings, setupPlan, clock, gradeChannel } from './morning-core.js';

const $ = (id) => document.getElementById(id);
const show = (id) => { for (const s of document.querySelectorAll('main > section')) s.classList.toggle('hidden', s.id !== id); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const WHERE = { O1: 'back left', O2: 'back right', T3: 'left side', T4: 'right side' };
let stopped = false, wake = null, audio = null, mode = 'morning';

async function mark(text) {
  try { await fetch('marker', { method: 'POST', body: text }); }
  catch (e) { $('err').textContent = 'Could not reach the laptop: is the recorder running?'; }
}

// soft sine tones with slow fades, so they do not startle with closed eyes
function tone(freqs) {
  if (!audio) return;
  let t = audio.currentTime + 0.05;
  for (const f of freqs) {
    const o = audio.createOscillator(), g = audio.createGain();
    o.type = 'sine'; o.frequency.value = f; o.connect(g); g.connect(audio.destination);
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(0.12, t + 0.15); g.gain.linearRampToValueAtTime(0, t + 0.9);
    o.start(t); o.stop(t + 1); t += 0.55;
  }
}
function startAudio() { try { audio = audio || new AudioContext(); audio.resume(); } catch (e) { audio = null; } }
async function keepAwake() { try { wake = await navigator.wakeLock.request('screen'); } catch (e) { wake = null; } }

// ---- contact
async function checkContact() {
  // The recorder measures contact by restarting itself (DECISIONS 17): its page server is away for ~20-40 s.
  $('begin').disabled = true; $('cstat').textContent = 'Checking contact: the recorder restarts, about 30 seconds…';
  let before = null;  // minutes recorded by the current recorder: the fresh one starts again near 0
  try { before = (await (await fetch('state', { cache: 'no-store' })).json()).minutes; } catch (e) { /* restarting */ }
  try { await fetch('contact', { method: 'POST' }); } catch (e) { /* it may already be restarting */ }
  await sleep(6000);
  for (let i = 0; i < 40; i++) {  // wait until the fresh recorder answers with new data (up to ~80 s)
    try { const s = await (await fetch('state', { cache: 'no-store' })).json(); if (s.age < 3 && s.minutes > 0 && (before === null || s.minutes < before)) break; } catch (e) { /* still restarting */ }
    await sleep(2000);
  }
  $('cstat').textContent = 'Contact and signal now (updates every second):'; $('begin').disabled = false;
}
async function pollState() {
  if ($('contact').classList.contains('hidden')) return;
  try {
    const s = await (await fetch('state')).json();
    $('chs').innerHTML = s.names.map((n, c) => {
      const g = gradeChannel(s.contact[n], s.data[c]); const ohm = s.contact[n];
      return `<div class="ch"><div><div class="name">${n}</div><div class="where">${WHERE[n]}</div></div>
        <div class="muted">${ohm === null ? 'no contact' : Math.round(ohm / 1000) + ' kΩ'} · ${g.spread.toFixed(0)} µV</div>
        <span class="badge ${g.grade}">${g.word}</span></div>`;
    }).join('');
  } catch (e) { $('cstat').textContent = 'Waiting for the laptop (the recorder may be reconnecting)…'; }
}

// ---- eyes closed / eyes open
async function runPhase(p) {
  $('ptitle').textContent = p.title; $('psay').textContent = p.say;
  const closed = p.key === 'eyes_closed';
  document.body.classList.toggle('dim', closed); $('dot').classList.toggle('hidden', closed);
  await mark(marker.phase(p.key, 'start'));
  const end = Date.now() + p.seconds * 1000;
  while (Date.now() < end && !stopped) { $('count').textContent = clock((end - Date.now()) / 1000); await sleep(250); }
  if (stopped) return false;
  await mark(marker.phase(p.key, 'end'));
  return true;
}
async function runMorning() {
  startAudio(); await keepAwake(); show('phase'); stopped = false;
  await mark(marker.start());
  const plan = morningPlan(phaseSeconds(location.search));
  tone([392]); // eyes closed now
  for (let k = 0; k < plan.length; k++) {
    if (!(await runPhase(plan[k]))) return;
    if (plan[k].key === 'eyes_closed') tone([392, 523.25]); // rising pair: open your eyes
    else tone([523.25]);
  }
  document.body.classList.remove('dim'); show('rate');
}

// ---- ratings
const ratings = { kss: null, mood: null, tension: null };
function scale(id, items) {
  $(id).innerHTML = items.map(([v, label]) => `<button data-v="${v}"><b>${v}</b><span>${label}</span></button>`).join('');
  $(id).onclick = (e) => {
    const b = e.target.closest('button'); if (!b) return;
    ratings[id] = Number(b.dataset.v);
    for (const x of $(id).children) x.classList.toggle('on', x === b);
    $('save').disabled = !validRatings(ratings);
  };
}
async function save() {
  if (!validRatings(ratings)) return;
  $('save').disabled = true;
  await mark(marker.ratings(ratings)); await mark(marker.end());
  if (wake) wake.release().catch(() => {});
  show('done');
}

// ---- setup test
async function runSetup() {
  startAudio(); await keepAwake(); show('setupsec'); stopped = false; mode = 'setup';
  const cues = setupPlan(); const t0 = Date.now();
  for (const c of cues) {
    while (Date.now() < t0 + c.at * 1000 && !stopped) await sleep(20);
    if (stopped) return;
    $('cue').textContent = c.show;
    if (c.tone) tone([440]);
    if (c.marker) mark(c.marker); // not awaited: the cue timing must not wait for the network
  }
  if (wake) wake.release().catch(() => {});
  $('dtitle').textContent = 'Setup test saved';
  $('dsay').textContent = 'To see which events the electrodes picked up, run on the laptop:';
  show('done');
}

async function stop() {
  stopped = true; document.body.classList.remove('dim');
  await mark(mode === 'setup' ? 'setup:abort' : marker.abort());
  if (wake) wake.release().catch(() => {});
  $('dtitle').textContent = 'Stopped'; $('dsay').textContent = 'Nothing was rated. You can start again any time.';
  show('done');
}

scale('kss', KSS); scale('mood', MOOD); scale('tension', TENSION);
$('go').onclick = () => { startAudio(); show('contact'); checkContact(); };
$('recheck').onclick = checkContact;
$('begin').onclick = runMorning;
$('save').onclick = save;
$('setup').onclick = runSetup;
$('stop').onclick = stop; $('stop2').onclick = stop;
setInterval(pollState, 1000);
if (phaseSeconds(location.search) !== 120) $('err').textContent = 'Short mode: 60 s phases (for testing).';
