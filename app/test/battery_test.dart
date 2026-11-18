import 'package:eeg_tracker/recorder/battery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const hour = 3600000;

  PhoneBattery b(int pct, int uah, {String plugged = 'no'}) =>
      PhoneBattery(percent: pct, chargeUah: uah, currentUa: -250000, plugged: plugged, tempC: 30);

  test('the summary gives percent and mAh per hour from the first to the last reading', () {
    final t = const BatteryTrack().add(b(80, 3200000), 0).add(b(79, 3150000), 4 * hour).add(b(72, 2880000), 8 * hour);
    expect(t.summaryLine(), 'phone battery summary: 8% in 8.0 h = 1.00 %/h, 320 mAh = 40 mAh/h');
  });

  test('a charger anywhere in the night is flagged', () {
    final t = const BatteryTrack()
        .add(b(80, 3200000), 0)
        .add(b(85, 3300000, plugged: 'usb'), hour)
        .add(b(84, 3280000), 2 * hour);
    expect(t.summaryLine(), contains('a charger was connected'));
  });

  test('too short a span or no readings gives no rate', () {
    expect(const BatteryTrack().summaryLine(), contains('no readings'));
    final t = const BatteryTrack().add(b(80, 3200000), 0).add(b(80, 3190000), 5 * 60000);
    expect(t.summaryLine(), contains('too short for a rate'));
  });

  test('a phone that gives no charge counter still gets the percent rate', () {
    const a = PhoneBattery(percent: 50);
    final t = const BatteryTrack().add(a, 0).add(const PhoneBattery(percent: 48), 2 * hour);
    expect(t.summaryLine(), 'phone battery summary: 2% in 2.0 h = 1.00 %/h');
  });

  test('the track and the readings survive JSON (a restarted app process)', () {
    final t = const BatteryTrack().add(b(80, 3200000), 1000).add(b(79, 3150000, plugged: 'ac'), 2 * hour);
    final back = BatteryTrack.fromJson(t.toJson());
    expect(back.first!.chargeUah, 3200000);
    expect(back.lastMs, 2 * hour);
    expect(back.pluggedSeen, isTrue);
    expect(back.summaryLine(), t.summaryLine());
    expect(BatteryTrack.fromJson(null).first, isNull);
  });

  test('log line format and the Kotlin map', () {
    final m = PhoneBattery.fromMap({
      'percent': 87,
      'chargeUah': 3612345,
      'currentUa': -310250,
      'plugged': 'no',
      'tempC': 31.24,
    });
    expect(m!.logLine(), 'battery 87% charge 3612345 uAh current -310250 uA unplugged temp 31.2 C');
    expect(PhoneBattery.fromMap({'plugged': 'usb'}), isNull); // nothing to measure
    expect(
      PhoneBattery.fromMap({'percent': 50})!.logLine(),
      'battery 50% charge ? uAh current ? uA plugged ? temp ? C',
    );
  });
}
