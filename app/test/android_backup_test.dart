// Recordings and the saved night state must never reach Google Drive backups or a device-to-device
// transfer (DECISIONS row 26). The manifest cannot be built here, so its settings are read as text.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _res = 'android/app/src/main/res/xml';
const List<String> _domains = [
  'root',
  'file',
  'database',
  'sharedpref',
  'external',
  'device_root',
  'device_file',
  'device_database',
  'device_sharedpref',
];

/// The text between `<tag ...>` and `</tag>`, or null.
String? _section(String xml, String tag) => RegExp('<$tag[^>]*>(.*?)</$tag>', dotAll: true).firstMatch(xml)?.group(1);

void _excludesEverything(String? rules, String where) {
  expect(rules, isNotNull, reason: '$where is missing');
  expect(rules, isNot(contains('<include')), reason: '$where must include nothing');
  for (final d in _domains) {
    expect(rules, contains('<exclude domain="$d" path="."'), reason: '$where must exclude the $d domain');
  }
}

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final application = RegExp(r'<application\b[^>]*>', dotAll: true).firstMatch(manifest)![0]!;

  test('backup is off', () {
    expect(application, contains('android:allowBackup="false"'));
  });

  test('Android 12+: neither cloud backup nor device transfer takes anything', () {
    expect(application, contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
    final xml = File('$_res/data_extraction_rules.xml').readAsStringSync();
    _excludesEverything(_section(xml, 'cloud-backup'), 'cloud-backup');
    _excludesEverything(_section(xml, 'device-transfer'), 'device-transfer');
  });

  test('Android 11 and older: the rules exclude everything too, should backup ever be turned on', () {
    expect(application, contains('android:fullBackupContent="@xml/backup_rules"'));
    final xml = File('$_res/backup_rules.xml').readAsStringSync();
    _excludesEverything(_section(xml, 'full-backup-content'), 'full-backup-content');
  });
}
