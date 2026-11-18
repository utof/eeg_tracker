// End-to-end check of sound.html against the recorder running the fake headband (not a unit test).
//   FAKE_BRAINBIT_SEED=3 PYTHONPATH=tests/fake_neurosdk python3 scripts/record_night.py --port 8765 --out /tmp/rec
//   node tests/web/fake_live_check.mjs /tmp/rec/<stamp>.log 360 [--no-cal] [--align] [shot.png]
// --align waits to press Start until the fake is 90 s into its 120 s cycle, so the 30 s eyes-open
// and 30 s eyes-closed calibration steps line up with the fake's weak and strong alpha.
// Opens the page in headless Chromium (Playwright), presses Start, listens for the given seconds,
// then lines the page's bells and calm values up with the fake signal's own clock (taken from the
// "recording started" line in the recorder log): eyes closed in even minutes, jaw 3 s every 45 s.
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
const { chromium } = createRequire(import.meta.url)('playwright');

const [logPath, secs = '360', ...rest] = process.argv.slice(2);
const calibrate = !rest.includes('--no-cal'), shot = rest.find((a) => a.endsWith('.png'));
const line = readFileSync(logPath, 'utf8').split('\n').find((l) => l.includes('recording started'));
const signalStart = new Date(line.split(' ')[0]).getTime();

const browser = await chromium.launch({ args: ['--autoplay-policy=no-user-gesture-required'] });
const page = await browser.newPage({ viewport: { width: 700, height: 1000 } });
const errors = [];
page.on('pageerror', (e) => errors.push(String(e)));
page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
await page.goto('http://localhost:8765/sound.html');
await page.waitForFunction(() => document.getElementById('src').value === 'live');
if (rest.includes('--align')) {
  const wait = ((90 - ((Date.now() - signalStart) / 1000) % 120) + 120) % 120;
  console.log(`waiting ${wait.toFixed(0)} s to line up with the fake signal`);
  await page.waitForTimeout(wait * 1000);
}
await page.click(calibrate ? '#go' : '#go2');
const total = Number(secs);
for (let s = 0; s < total; s += 30) {
  await page.waitForTimeout(Math.min(30, total - s) * 1000);
  const say = await page.textContent('#say');
  console.log(`${Math.min(total, s + 30)} s: ${say}`);
}
if (shot) await page.screenshot({ path: shot });
const notePromise = Promise.all([page.textContent('#base'), page.textContent('#why')]).then((a) => a.join(' / '));
const log = await page.evaluate(() => window.__sound);
await page.click('#stop');
await browser.close();

const fakeT = (t) => (log.t0wall + t * 1000 - signalStart) / 1000 - 0.1;  // data in the page lags ~0.1 s
const closed = (ft) => Math.floor(ft / 60) % 2 === 0;
const steps = log.steps.filter((s) => s.quality === 'good').map((s) => ({ ...s, ft: fakeT(s.t) }));
const settled = steps.filter((s) => s.ft % 60 > 4);
const mean = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : NaN);
const cClosed = mean(settled.filter((s) => closed(s.ft)).map((s) => s.calm));
const cOpen = mean(settled.filter((s) => !closed(s.ft)).map((s) => s.calm));
const jawSteps = steps.filter((s) => s.ft % 45 > 0.5 && s.ft % 45 < 3);
const bells = log.bells.map((b) => fakeT(b.t));
const badBells = bells.filter((ft) => ft % 45 < 3 + 2 + 3 - 0.75 || !closed(ft - 1));
console.log(JSON.stringify({
  calibrate, note: await notePromise, steps: log.steps.length, goodSteps: steps.length, cues: log.cues,
  calmEyesClosed: +cClosed.toFixed(3), calmEyesOpen: +cOpen.toFixed(3),
  jawSteps: jawSteps.length, bellsAllowedDuringJaw: jawSteps.filter((s) => s.bellsAllowed).length,
  meanRoughDuringJaw: +mean(jawSteps.map((s) => s.rough)).toFixed(2),
  bells: bells.length, bellFakeTimes: bells.map((b) => +b.toFixed(1)), bellsNearJawOrEyesOpen: badBells.length, errors,
}, null, 1));
const ok = cClosed > cOpen + 0.5 && badBells.length === 0 && bells.length > 0 && !errors.length
  && jawSteps.every((s) => !s.bellsAllowed);
console.log(ok ? 'PASS' : 'FAIL');
process.exit(ok ? 0 : 1);
