// Session log: everything needed to replay a session bit for bit, kept in memory.
//   header  : mode, calibration on/off, sample rate, channel names, version
//   lines   : JSON lines in order: every input event ({type:'gap'|'contact', n}), one 'step' line per
//             analysis step (the sound-control stream: calm, rough, gates, line, bells), and events
//             ('cue', 'calibration', 'block', 'bell')
//   input   : every sample the core used, as float32 per channel
//   info    : notes from the page (audio delay, dropouts, stream position); not part of the replay
// toJSON() gives one object that saves as a session file; replaySession() (sound-source.js) feeds its
// input through a fresh core and must produce the same lines.
//
// Port notes (Dart): Float32List per channel (growable by copying), base64 from dart:convert of the
// little-endian bytes; lines as a List<Map<String, Object?>>. Replay is exact within one engine; sin, exp
// and log can differ in the last bit between JS and Dart, so compare a JS log in Dart with a small tolerance.

export const LOG_VERSION = 1;

export class SessionLog {
  constructor(header, channels = 4) {
    this.header = { type: 'header', version: LOG_VERSION, ...header };
    this.lines = []; this.info = [];
    this.data = []; for (let c = 0; c < channels; c++) this.data.push(new Float32Array(4096));
    this.n = 0;
  }

  sample(row) {   // row: already rounded to float32 by the core
    if (this.n === this.data[0].length) {
      this.data = this.data.map((a) => { const b = new Float32Array(a.length * 2); b.set(a); return b; });
    }
    for (let c = 0; c < this.data.length; c++) this.data[c][this.n] = row[c];
    this.n++;
  }

  line(obj) { this.lines.push(obj); }
  note(obj) { this.info.push(obj); }

  toJSON() {
    const input = { encoding: 'float32-le-base64', samples: this.n, channels: this.data.map((a) => toBase64(a.subarray(0, this.n))) };
    return { header: this.header, info: this.info, lines: this.lines, input };
  }
}

// Input channels of a saved session, as Float32Arrays.
export function decodeInput(input) {
  if (!input || input.encoding !== 'float32-le-base64') throw new Error('not a session file');
  return input.channels.map((s) => fromBase64(s, input.samples));
}

function toBase64(f32) {
  const bytes = new Uint8Array(f32.length * 4), view = new DataView(bytes.buffer);
  for (let i = 0; i < f32.length; i++) view.setFloat32(i * 4, f32[i], true);
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

function fromBase64(b64, n) {
  const s = atob(b64), view = new DataView(new ArrayBuffer(s.length));
  for (let i = 0; i < s.length; i++) view.setUint8(i, s.charCodeAt(i));
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = view.getFloat32(i * 4, true);
  return out;
}
