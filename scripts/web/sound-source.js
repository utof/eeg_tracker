// Signal sources behind one seam. A source calls its sink with:
//   sink.rows(rows)     new samples, [[O1, O2, T3, T4], ...] in µV, in order
//   sink.gap()          samples were lost (link dropped, recorder restarted, tab asleep)
//   sink.contact(c)     contact per channel from the recorder ({O1: ohms | null, ...})
//   sink.status(text)   something to show (connecting, reconnecting, replay finished)
// Sources: LiveSource (the recorder's GET /stream), DemoSource (sound-demo.js), ReplaySource (a saved
// session). The core (sound-session.js) does not know which one feeds it.
//
// Port notes (Dart): StreamReader and replaySession are pure and port as they are. LiveSource maps to
// the phone app's own BrainBit stream (NeuroSDK2 callbacks), DemoSource and ReplaySource to a Timer.

import { FS, NAMES } from './sound-features.js';
import { Session } from './sound-session.js';
import { decodeInput } from './sound-log.js';

export const GAP_S = 1;   // a pause in the recorder's arrival times longer than this (beyond the batch) is a gap

// Reads the parsed messages of GET /stream: a hello, then batches {"i", "t", "uv": [[...], ...]} and markers.
// Returns {rows, gap, hello} or null for messages without samples (markers).
export class StreamReader {
  constructor() { this.next = null; this.lastT = null; this.order = null; }

  read(msg) {
    if (msg.hello) {
      const order = NAMES.map((nm) => (msg.names || []).indexOf(nm));
      if (msg.fs !== FS || order.includes(-1)) throw new Error(`stream has ${msg.names} at ${msg.fs} Hz; expected ${NAMES} at ${FS} Hz`);
      const gap = this.next !== null;   // a second hello: reconnected, samples were missed
      this.order = order; this.next = msg.next_i ?? null; this.lastT = null;
      return { rows: [], gap, hello: msg };
    }
    if (!Array.isArray(msg.uv) || !this.order) return null;
    let gap = false;
    if (this.next !== null && msg.i !== this.next) gap = true;
    if (this.lastT !== null && msg.t - this.lastT > GAP_S + msg.uv.length / FS) gap = true;
    this.next = msg.i + msg.uv.length; this.lastT = msg.t;
    return { rows: msg.uv.map((r) => this.order.map((j) => r[j])), gap, i: msg.i, t: msg.t };
  }
}

// The recorder's live stream (server-sent events). Contact comes from GET /state (measured when the
// recorder connects), read at the start and every 10 s.
export class LiveSource {
  constructor(base = '') { this.base = base; this.kind = 'live'; }

  async start(sink) {
    this.sink = sink; this.reader = new StreamReader(); this.lastContact = undefined;
    await this.readContact();
    this.contactTimer = setInterval(() => this.readContact(), 10000);
    this.es = new EventSource(this.base + 'stream');
    this.es.onmessage = (e) => {
      let r;
      try { r = this.reader.read(JSON.parse(e.data)); } catch (err) { sink.status(String(err.message || err)); return; }
      if (!r) return;
      if (r.hello && this.firstI === undefined) this.firstI = r.hello.next_i;
      if (r.gap) sink.gap();
      if (r.rows.length) sink.rows(r.rows, r);
    };
    this.es.onerror = () => sink.status('Recorder stream lost: reconnecting');
  }

  async readContact() {
    try {
      const s = await (await fetch(this.base + 'state', { cache: 'no-store' })).json();
      const c = s.contact || null, key = JSON.stringify(c);
      if (key !== this.lastContact) { this.lastContact = key; this.sink.contact(c); }
    } catch { /* the stream itself reports problems */ }
  }

  stop() { if (this.es) this.es.close(); clearInterval(this.contactTimer); }
}

// Plays samples at the real pace from a function next(k) -> rows (the demo, or a saved session).
class PacedSource {
  start(sink) {
    this.sink = sink; this.t0 = performance.now(); this.made = 0;
    this.timer = setInterval(() => this.tick(), 40);
  }
  tick() {
    const due = Math.floor(((performance.now() - this.t0) / 1000) * FS);
    let k = due - this.made;
    if (k > 4 * FS) {   // the tab slept: drop what was missed, and say so
      this.sink.gap(); this.skip(k - FS); this.made += k - FS; k = FS;
    }
    if (k > 0) { const rows = this.next(k); this.made += k; if (rows.length) this.sink.rows(rows); }
  }
  stop() { clearInterval(this.timer); }
}

export class DemoSource extends PacedSource {
  constructor(demo) { super(); this.demo = demo; this.kind = 'demo'; }
  next(k) { return this.demo.next(k); }
  skip(k) { this.demo.next(k); }
}

// A saved session (SessionLog.toJSON()) played at the real pace, with its gaps and contact changes
// at the same samples.
export class ReplaySource extends PacedSource {
  constructor(saved) {
    super(); this.kind = 'replay';
    this.input = decodeInput(saved.input); this.events = inputEvents(saved.lines); this.pos = 0; this.ev = 0;
  }
  next(k) {
    const end = Math.min(this.pos + k, this.input[0].length), rows = [];
    while (this.pos < end) {
      while (this.ev < this.events.length && this.events[this.ev].n <= this.pos) this.apply(this.events[this.ev++], rows);
      rows.push(this.input.map((ch) => ch[this.pos])); this.pos++;
    }
    if (this.pos >= this.input[0].length) { this.stop(); this.sink.status('Replay finished'); }
    return rows;
  }
  apply(e, rows) {   // pass on what came before the event first, so it lands at the same sample
    if (rows.length) { this.sink.rows(rows.splice(0)); }
    if (e.type === 'gap') this.sink.gap(); else this.sink.contact(e.contact);
  }
  skip(k) { this.next(k); }
}

const inputEvents = (lines) => lines.filter((l) => l.type === 'gap' || l.type === 'contact');

// Feed a saved session through a fresh core, as fast as possible. Returns the new core; its log.lines
// must equal the saved lines exactly (tests/web/feedback-core.test.mjs).
export function replaySession(saved, chunk = 37) {
  const s = new Session({ mode: saved.header.mode, calibrate: saved.header.calibrate });
  const input = decodeInput(saved.input), total = input[0].length;
  let pos = 0;
  const feedTo = (end) => {
    while (pos < end) {
      const stop = Math.min(end, pos + chunk), rows = [];
      for (; pos < stop; pos++) rows.push(input.map((ch) => ch[pos]));
      s.push(rows);
    }
  };
  for (const e of inputEvents(saved.lines)) {
    feedTo(e.n);
    if (e.type === 'gap') s.gap(); else s.contact(e.contact ?? undefined);
  }
  feedTo(total);
  return s;
}
