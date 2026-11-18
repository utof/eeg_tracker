// Session log: everything needed to replay a session bit for bit (DECISIONS row 47). A port of
// scripts/web/sound-log.js; the JSON it writes is the same format, so a phone session replays on the laptop
// page's core and a page session replays here.
//   header : mode, calibration on/off, sample rate, channel names, version
//   lines  : JSON lines in order: input events ({type: 'gap' | 'contact', n}), one 'step' line per analysis
//            step (the sound-control stream), and events ('cue', 'calibration', 'block', 'bell')
//   input  : every sample the core used, as float32 per channel (little-endian, base64)
//   info   : notes from the app (audio delay, headband); not part of the replay
import 'dart:convert';
import 'dart:typed_data';

const int logVersion = 1;

class SessionLog {
  SessionLog(Map<String, Object?> header, [int channels = 4])
    : header = {'type': 'header', 'version': logVersion, ...header},
      _data = List.generate(channels, (_) => Float32List(4096));

  final Map<String, Object?> header;
  final List<Map<String, Object?>> lines = [];
  final List<Map<String, Object?>> info = [];
  List<Float32List> _data;
  int n = 0;

  /// [row]: already rounded to float32 by the core.
  void sample(List<double> row) {
    if (n == _data[0].length) {
      _data = [for (final a in _data) Float32List(a.length * 2)..setRange(0, a.length, a)];
    }
    for (var c = 0; c < _data.length; c++) {
      _data[c][n] = row[c];
    }
    n++;
  }

  void line(Map<String, Object?> obj) => lines.add(obj);
  void note(Map<String, Object?> obj) => info.add(obj);

  Map<String, Object?> toJson() => {
    'header': header,
    'info': info,
    'lines': lines,
    'input': {
      'encoding': 'float32-le-base64',
      'samples': n,
      'channels': [for (final a in _data) _toBase64(a, n)],
    },
  };
}

/// Input channels of a saved session. Throws [FormatException] on anything that is not a session file.
List<Float32List> decodeInput(Object? input) {
  if (input is! Map || input['encoding'] != 'float32-le-base64') throw const FormatException('not a session file');
  final samples = input['samples'], channels = input['channels'];
  if (samples is! int || samples < 0 || channels is! List || channels.isEmpty) {
    throw const FormatException('session file: bad input block');
  }
  return [
    for (final s in channels)
      if (s is String) _fromBase64(s, samples) else throw const FormatException('session file: channel is not text'),
  ];
}

String _toBase64(Float32List a, int n) {
  final bytes = ByteData(n * 4);
  for (var i = 0; i < n; i++) {
    bytes.setFloat32(i * 4, a[i], Endian.little);
  }
  return base64.encode(bytes.buffer.asUint8List());
}

Float32List _fromBase64(String b64, int n) {
  final bytes = base64.decode(b64);
  if (bytes.length < n * 4) throw const FormatException('session file: channel shorter than its sample count');
  final view = ByteData.sublistView(bytes), out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = view.getFloat32(i * 4, Endian.little);
  }
  return out;
}
