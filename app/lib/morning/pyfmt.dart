// Python's number rounding and formatting, so the phone writes the same numbers and texts as
// scripts/morning_check.py: `round(x, n)`, `f"{x:.nf}"` and `f"{x:.3g}"` round the exact binary value of x, and an
// exact tie (28.25 to one decimal) goes to the even digit. Dart's toStringAsFixed rounds a tie up, so the rounding
// here is done with exact integer arithmetic.
import 'dart:typed_data';

final BigInt _ten = BigInt.from(10);

/// |x| as an exact fraction numerator / 2^shift.
(BigInt, int) _exact(double x) {
  final bits = ByteData(8)..setFloat64(0, x.abs());
  final hi = bits.getUint32(0), lo = bits.getUint32(4);
  final expBits = (hi >> 20) & 0x7FF;
  var mant = (BigInt.from(hi & 0xFFFFF) << 32) | BigInt.from(lo);
  var e = -1074; // subnormal
  if (expBits != 0) {
    mant |= BigInt.one << 52;
    e = expBits - 1075;
  }
  return e >= 0 ? (mant << e, 0) : (mant, -e);
}

/// |x| * 10^decimals rounded to an integer, an exact tie to the even one (decimals may be negative).
BigInt _scaledRound(double x, int decimals) {
  final (num, shift) = _exact(x);
  var n = num, d = BigInt.one << shift;
  if (decimals >= 0) {
    n *= _ten.pow(decimals);
  } else {
    d *= _ten.pow(-decimals);
  }
  final q = n ~/ d, twice = (n - q * d) * BigInt.two;
  if (twice > d || (twice == d && q.isOdd)) return q + BigInt.one;
  return q;
}

String _point(BigInt n, int decimals) {
  if (decimals <= 0) return (n * _ten.pow(-decimals)).toString();
  final s = n.toString().padLeft(decimals + 1, '0');
  return '${s.substring(0, s.length - decimals)}.${s.substring(s.length - decimals)}';
}

/// `f"{x:.{decimals}f}"`.
String pyFixed(double x, int decimals) {
  if (!x.isFinite) return x.isNaN ? 'nan' : (x > 0 ? 'inf' : '-inf');
  final s = _point(_scaledRound(x, decimals), decimals);
  return x.isNegative ? '-$s' : s;
}

/// `round(x, decimals)`.
double pyRound(double x, int decimals) => x.isFinite ? double.parse(pyFixed(x, decimals)) : x;

/// `f"{x:.3g}"`: three significant digits without trailing zeros; exponent form below 1e-4 and from 1000.
String pyG3(double x) {
  if (x == 0) return '0';
  if (!x.isFinite) return pyFixed(x, 0);
  var exp = int.parse(x.abs().toStringAsExponential(15).split('e')[1]);
  var n = _scaledRound(x, 2 - exp);
  if (n >= BigInt.from(1000)) {
    exp += 1; // 9.996 -> 10.0
    n = _scaledRound(x, 2 - exp);
  }
  final sign = x.isNegative ? '-' : '';
  if (exp < -4 || exp >= 3) {
    final d = n.toString();
    final mant = _strip('${d[0]}.${d.substring(1)}');
    return '$sign${mant}e${exp < 0 ? '-' : '+'}${exp.abs().toString().padLeft(2, '0')}';
  }
  return '$sign${_strip(_point(n, 2 - exp))}';
}

String _strip(String s) {
  if (!s.contains('.')) return s;
  final t = s.replaceFirst(RegExp(r'0+$'), '');
  return t.endsWith('.') ? t.substring(0, t.length - 1) : t;
}
