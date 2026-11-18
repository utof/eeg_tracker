// Writes js_session.json: a short session run by the laptop page's JavaScript core (scripts/web) on its demo
// signal, for the Dart cross-check (test/feedback_cross_check_test.dart). From the repo root:
//   node app/test/fixtures/make_js_session.mjs
// 150 s: contact at the start, 30 s eyes open + eyes closed (calibration), no blinks and 1.5x alpha 95-128 s (bells),
// a 2 s hole at 115 s, eyes open 128-134 s. Regenerate only when the JS core changes, and commit the JSON with the change.
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Session, STEP } from '../../../scripts/web/sound-session.js';
import { DemoSignal } from '../../../scripts/web/sound-demo.js';

const s = new Session({ mode: 'training', calibrate: true }), demo = new DemoSignal(11);
s.contact({ O1: 4e5, O2: 6e5, T3: 1.2e6, T4: 9e5 });
while (demo.t < 150) {
  const t = demo.t;
  demo.eyes = t < 30 || (t >= 128 && t < 134) ? 'open' : 'closed';
  demo.blinks = !(t >= 95 && t < 128);
  demo.alphaGain = t >= 95 && t < 128 ? 1.5 : 1;
  if (Math.abs(t - 115) < 1e-9) { s.gap(); demo.next(500); }
  s.push(demo.next(STEP));
}
const saved = s.log.toJSON();
saved.info.push({ made: 'app/test/fixtures/make_js_session.mjs', bells: s.rung });
writeFileSync(join(dirname(fileURLToPath(import.meta.url)), 'js_session.json'), JSON.stringify(saved));
console.log(`${s.n} samples, ${s.log.lines.length} lines, ${s.rung} bells, phase ${s.phase}, note: ${s.note}`);
