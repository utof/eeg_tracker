// The Signal view's electrode layouts (DECISIONS 591-592): the 10-10 sites built on the ideal sphere, the old names,
// the BrainBit's and the DIY board's layouts, the helmet plans, any number of channels, and positions typed by hand
// as angles or x/y/z.
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/signal/layout.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher _near(Vec3 v, [double tol = 1e-9]) => isA<Vec3>()
    .having((p) => p.x, 'x', closeTo(v.x, tol))
    .having((p) => p.y, 'y', closeTo(v.y, tol))
    .having((p) => p.z, 'z', closeTo(v.z, tol));

double _chord(String a, String b) => (standardSites[a]! - standardSites[b]!).length;

double _angleDeg(Vec3 a, Vec3 b) => math.acos(a.unit.dot(b.unit).clamp(-1.0, 1.0)) * 180 / math.pi;

void main() {
  group('the 10-10 sites', () {
    test('the landmarks of the ideal sphere: top, front, back, ears', () {
      expect(standardSites['Cz'], _near(const Vec3(0, 0, 1)));
      expect(standardSites['Fpz'], _near(const Vec3(0, 1, 0)));
      expect(standardSites['Oz'], _near(const Vec3(0, -1, 0)));
      expect(standardSites['T7'], _near(const Vec3(-1, 0, 0)));
      expect(standardSites['T8'], _near(const Vec3(1, 0, 0)));
      // 10 % of the nasion-inion arc is 22.5 degrees from the vertex down: Fz at 45, Pz at 45 behind
      expect(toAngles(standardSites['Fz']!).polar, closeTo(45, 1e-9));
      expect(toAngles(standardSites['Pz']!).azimuth.abs(), closeTo(180, 1e-9));
      expect(toAngles(standardSites['Nz']!).polar, closeTo(112.5, 1e-9));
    });

    test('every site is a direction (unit length), and there are the 10-10 sites at least', () {
      for (final e in standardSites.entries) {
        expect(e.value.length, closeTo(1, 1e-9), reason: e.key);
      }
      for (final n in ['Fp1', 'AF3', 'F7', 'F3', 'FC5', 'C3', 'CP1', 'P7', 'PO3', 'O1', 'T9', 'TP10', 'Iz', 'M1', 'A2']) {
        expect(standardSites, contains(n));
      }
      expect(standardSites.length, greaterThanOrEqualTo(80));
    });

    test('left and right are mirror images (odd numbers left, even right)', () {
      for (final e in standardSites.entries) {
        final m = RegExp(r'^([A-Za-z]+)(\d+)$').firstMatch(e.key);
        if (m == null || int.parse(m.group(2)!).isEven) continue;
        final right = standardSites['${m.group(1)}${int.parse(m.group(2)!) + 1}'];
        expect(right, isNotNull, reason: e.key);
        expect(right, _near(e.value.mirrored), reason: e.key);
        expect(e.value.x, lessThan(0), reason: '${e.key} is on the left');
      }
    });

    test('each row is cut into four equal steps from its side to the midline (F7 F5 F3 F1 Fz)', () {
      for (final (p, side, mid) in [('F', 'F7', 'Fz'), ('C', 'T7', 'Cz'), ('P', 'P7', 'Pz'), ('FC', 'FT7', 'FCz')]) {
        final steps = [_chord(side, '${p}5'), _chord('${p}5', '${p}3'), _chord('${p}3', '${p}1'), _chord('${p}1', mid)];
        for (final s in steps) {
          expect(s, closeTo(steps.first, 1e-9), reason: p);
        }
      }
      // the C row lies on the great circle ear to ear: C3 at 45 degrees down on the left, C5 at 67.5
      expect(standardSites['C3'], _near(fromAngles(45, -90)));
      expect(standardSites['C5'], _near(fromAngles(67.5, -90)));
    });

    test('F3 lands where the published idealised 10-20 sphere puts it (about 60 degrees down, 40 round)', () {
      // An independent figure: the spherical 10-20 head (e.g. EEGLAB's and BESA's idealised caps) has F3 a little
      // above halfway between the vertex and the ear line, between the nose line and the ear line.
      final a = toAngles(standardSites['F3']!);
      expect(a.polar, inInclusiveRange(55, 66));
      expect(a.azimuth, inInclusiveRange(-48, -35));
      // the 10-20 ring: F7 and O1 at 54 and 162 degrees round, on the 90-degree ring
      expect(toAngles(standardSites['F7']!).azimuth, closeTo(-54, 1e-9));
      expect(toAngles(standardSites['O1']!).azimuth, closeTo(-162, 1e-9));
      expect(_angleDeg(standardSites['O1']!, standardSites['O2']!), closeTo(36, 1e-9));
    });

    test('names in any case, and the old names T3 T4 T5 T6', () {
      expect(standardName('fp1'), 'Fp1');
      expect(standardName('CZ'), 'Cz');
      expect(standardName('T3'), 'T7');
      expect(standardName('t4'), 'T8');
      expect(standardName('T5'), 'P7');
      expect(standardName('T6'), 'P8');
      expect(standardName('X1'), isNull);
      expect(standardPosition('T3'), _near(standardSites['T7']!));
    });

    test('angles both ways', () {
      for (final (p, a) in [(0.0, 0.0), (30.0, 45.0), (90.0, -90.0), (120.0, 170.0), (60.0, -30.0)]) {
        final back = toAngles(fromAngles(p, a));
        expect(back.polar, closeTo(p, 1e-9));
        if (p > 0) expect(back.azimuth, closeTo(a, 1e-9));
      }
    });
  });

  group('the devices', () {
    test('BrainBit: O1 O2 T3 T4 in its order, against a forehead reference', () {
      final m = brainBitMontage();
      expect(m.names, ['O1', 'O2', 'T3', 'T4']);
      expect(m.channels.every((s) => s.at != null), isTrue);
      expect(m.site('T3')!.at, _near(standardSites['T7']!));
      final ref = m.others.single;
      expect(ref.kind, SiteKind.reference);
      expect(ref.where, 'forehead');
      expect(ref.at, _near(standardSites['Fpz']!));
      expect(m.unplaced, isEmpty);
    });

    test('the DIY board: its channel names from the setting, reference and bias on the earlobes', () {
      final m = diyBoardMontage(const ['O1', 'O2', 'Fz', 'Fp1']);
      expect(m.names, ['O1', 'O2', 'Fz', 'Fp1']);
      expect(m.others.map((s) => s.kind), [SiteKind.reference, SiteKind.ground]);
      expect(m.others.map((s) => s.where), ['an earlobe', 'the other earlobe']);
      // a name the 10-10 system does not know is listed but not placed
      final odd = diyBoardMontage(const ['CH1', 'O2', 'X9', 'Cz']);
      expect(odd.unplaced.map((s) => s.name), ['CH1', 'X9']);
      expect(odd.count, 4);
    });

    test('any number of channels: 4, 8 and 16, in the order given', () {
      expect(helmetPlan8().names, ['M1', 'M2', 'F7', 'F8', 'Fz', 'C3', 'C4', 'Pz']);
      expect(helmetPlan8().site('M1')!.approximate, isTrue);
      final h16 = helmetPlan16();
      expect(h16.count, 16);
      expect(h16.unplaced, isEmpty);
      expect(h16.names, containsAll(['O1', 'O2', 'T7', 'T8'])); // the headband's sites carry over
      final many = montageFromNames('Cap', [for (var i = 1; i <= 64; i++) 'E$i']);
      expect(many.count, 64);
      expect(many.unplaced, hasLength(64));
    });
  });

  group('positions typed by hand', () {
    test('angles, x y z, a 10-10 name alone, the reference and the ground; comments and blank lines', () {
      final p = parsePositions('''
# my helmet
X1 60 30
X2 0.3, 0.5, 0.8
C3

ref Fpz
ground GND 100 0   # under the forehead
''');
      expect(p.sites['X1'], _near(fromAngles(60, 30)));
      expect(p.sites['X2'], _near(const Vec3(0.3, 0.5, 0.8).unit));
      expect(p.sites['C3'], _near(standardSites['C3']!));
      expect(p.reference!.name, 'Fpz');
      expect(p.reference!.at, _near(standardSites['Fpz']!));
      expect(p.ground!.name, 'GND');
      expect(p.ground!.kind, SiteKind.ground);
      expect(p.ground!.at, _near(fromAngles(100, 0)));
    });

    test('every refusal names its line and what to do', () {
      void bad(String text, int line, String part) {
        expect(
          () => parsePositions(text),
          throwsA(isA<PositionsError>().having((e) => e.line, 'line', line).having((e) => e.message, 'message', contains(part))),
          reason: text,
        );
      }

      bad('X1', 1, 'not a 10-10 name');
      bad('O1\nX1 200 0', 2, 'polar is 0');
      bad('X1 60 400', 1, 'azimuth');
      bad('X1 0 0 0', 1, 'cannot all be 0');
      bad('X1 1 2 3 4', 1, 'give 2 numbers');
      bad('X1 60 north', 1, 'only numbers');
      bad('X1 60 30\nX1 10 10', 2, 'twice');
      bad('bad/name 1 2', 1, 'not a name');
      bad('ref', 1, 'give a name');
      bad('ref Fpz\nreference Cz', 2, 'reference is given twice');
      bad('X1 NaN 3', 1, 'only numbers');
    });

    test('the file\'s places go to the channels it names; the rest keep their own; ref and ground replace', () {
      final device = diyBoardMontage(const ['X1', 'O2', 'X9', 'Cz']);
      final m = withPositions(device, parsePositions('X1 60 30\nX9 0 1 0\nref Fpz'));
      expect(m.site('X1')!.at, _near(fromAngles(60, 30)));
      expect(m.site('X1')!.custom, isTrue);
      expect(m.site('X9')!.at, _near(const Vec3(0, 1, 0)));
      expect(m.site('O2')!.at, _near(standardSites['O2']!));
      expect(m.site('O2')!.custom, isFalse);
      expect(m.unplaced, isEmpty);
      expect(m.others.firstWhere((s) => s.kind == SiteKind.reference).name, 'Fpz');
      expect(m.others.firstWhere((s) => s.kind == SiteKind.ground).name, 'Bias'); // not given: the device's stays
      expect(withPositions(device, const CustomPositions()), same(device));
    });

    test('the store checks before it writes, and a missing or broken file places nothing', () {
      final dir = Directory.systemTemp.createTempSync('signal_positions');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = PositionsStore(Directory('${dir.path}/signal'));
      expect(store.read(), '');
      expect(store.load().isEmpty, isTrue);
      expect(() => store.write('X1 400 0'), throwsA(isA<PositionsError>()));
      expect(store.file.existsSync(), isFalse);
      store.write('X1 60 30');
      expect(store.load().sites.keys, ['X1']);
      store.file.writeAsStringSync('X1 nonsense');
      expect(store.load().isEmpty, isTrue);
      expect(signalDirFor('/data/files/recordings').path, '/data/files/signal');
    });
  });

  test('places in words', () {
    expect(placeWords(standardSites['Cz']!), 'top');
    expect(placeWords(standardSites['O1']!), 'back left');
    expect(placeWords(standardSites['O2']!), 'back right');
    expect(placeWords(standardSites['T7']!), 'left side');
    expect(placeWords(standardSites['Fpz']!), 'front');
    expect(placeWords(standardSites['M1']!), 'low back left');
  });
}
