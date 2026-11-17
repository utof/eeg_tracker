# Android Health Connect for the EEG sleep app

Research note, 2026-11-17. Scope: what this app could read from and write to Health Connect, which Flutter
package to use, the manifest and permission setup, and Google Play rules. Related decision: DECISIONS.md row 10
(Health Connect was listed as a sync alternative, "sleep only").

## Answer in 5 lines

1. Health Connect fits as an optional extra: write one sleep session per night with stages, and read heart rate, resting HR, HRV, steps and other apps' sleep to compare.
2. On the owner's Android 14 phone Health Connect is built into the system, so nothing extra needs installing; the app needs `minSdk` 26, a privacy-policy screen, and the right manifest entries.
3. The popular `health` package (13.3.2, MIT, carp.dk) reads everything we need, but it cannot write one sleep session with many stages (it writes one record per stage), and on Android it has no mindfulness type.
4. `health_connector` (3.14.1, MIT, very active) can write a proper multi-stage session with a head-mounted device type and a stable ID, and supports mindfulness; use it, or a small Kotlin method channel.
5. Google Play forms (Health apps declaration, Data safety, privacy policy) matter only if we publish on Play; a sideloaded or F-Droid build on Android 14 needs no Play forms, but still needs the privacy-policy activity.

## Evidence

### 1. Record types useful here (Health Connect Jetpack SDK `androidx.health.connect:connect-client`)

- **SleepSessionRecord** [verified]
  ([reference](https://developer.android.com/reference/kotlin/androidx/health/connect/client/records/SleepSessionRecord)).
  Constructor (added in 1.1.0):
  `SleepSessionRecord(startTime: Instant, startZoneOffset: ZoneOffset?, endTime: Instant, endZoneOffset: ZoneOffset?, metadata: Metadata, title: String? = null, notes: String? = null, stages: List<SleepSessionRecord.Stage> = emptyList())`.
  "All sleep stage time intervals should fall within the sleep session interval. Time intervals for stages don't need
  to be continuous but shouldn't overlap." Aggregate metric: `SLEEP_DURATION_TOTAL`.
  Stage constants (exact values from the page):

  | Constant | Value | Meaning (from the page) | EEG hypnogram mapping (our choice) |
  |---|---|---|---|
  | `STAGE_TYPE_UNKNOWN` | 0 | stage unknown | epochs with bad contact / artefact |
  | `STAGE_TYPE_AWAKE` | 1 | awake, in bed or unknown | W |
  | `STAGE_TYPE_SLEEPING` | 2 | asleep, stage unknown | low-confidence sleep (model disagreement) |
  | `STAGE_TYPE_OUT_OF_BED` | 3 | out of bed, assumed awake | headband off / no signal (only if we know) |
  | `STAGE_TYPE_LIGHT` | 4 | light sleep | N1 + N2 |
  | `STAGE_TYPE_DEEP` | 5 | deep sleep | N3 |
  | `STAGE_TYPE_REM` | 6 | REM | REM |
  | `STAGE_TYPE_AWAKE_IN_BED` | 7 | awake and in bed | W while headband is on (we know they're in bed) |

  The mapping column is my proposal [inferred]: Health Connect has no N1/N2 split, so N1 and N2 both become LIGHT;
  this is the same collapse consumer wearables use.
- **HeartRateRecord** (series of `samples` with `time` + `beatsPerMinute`), **RestingHeartRateRecord**,
  **HeartRateVariabilityRmssdRecord** (`heartRateVariabilityMillis`), **StepsRecord**, **ExerciseSessionRecord**
  [verified]: all are listed with read/write permissions on the
  [data types page](https://developer.android.com/health-and-fitness/guides/health-connect/plan/data-types)
  (permissions `READ_/WRITE_HEART_RATE`, `READ_/WRITE_RESTING_HEART_RATE`, `READ_/WRITE_HEART_RATE_VARIABILITY`,
  `READ_/WRITE_STEPS`, `READ_/WRITE_EXERCISE`).
  The BrainBit Black reports no pulse or motion sensor (DECISIONS.md), so this app can only **read** these, not write them [inferred].
- **MindfulnessSessionRecord** [verified]
  ([Jetpack reference](https://developer.android.com/reference/kotlin/androidx/health/connect/client/records/MindfulnessSessionRecord),
  [guide](https://developer.android.com/health-and-fitness/guides/health-connect/develop/mindfulness)).
  Constructor: `MindfulnessSessionRecord(startTime, startZoneOffset, endTime, endZoneOffset, metadata, mindfulnessSessionType: Int, title: String?, notes: String?)`.
  Types: `UNKNOWN=0, MEDITATION=1, BREATHING=2, MUSIC=3, MOVEMENT=4, UNGUIDED=5`. Permissions
  `android.permission.health.READ_MINDFULNESS` / `WRITE_MINDFULNESS`.
  History and availability:
  - Jetpack: experimental in `connect-client` 1.1.0-beta02 (April 9, 2025); feature flag added 1.1.0-rc01 (April 23, 2025);
    stable in 1.1.0 (October 8, 2025); "backwards compatibility support for Mindfulness" in 1.2.0-alpha01 (July 30, 2025)
    ([release notes](https://developer.android.com/jetpack/androidx/releases/health-connect)) [verified].
  - The record page says insert/read "is dependent on the version of HealthConnect installed on the device": check
    `HealthConnectFeatures.getFeatureStatus(FEATURE_MINDFULNESS_SESSION) == FEATURE_STATUS_AVAILABLE` [verified].
  - Android framework: `android.health.connect.datatypes.MindfulnessSessionRecord` is "Added in API level 36. Also in
    U Extensions 15" ([framework reference](https://developer.android.com/reference/android/health/connect/datatypes/MindfulnessSessionRecord)) [verified].
    So on the owner's Android 14 (API 34) phone it works only if the system's SDK extension level is 15 or more
    (mainline update); check the feature flag at runtime rather than assuming [inferred].
  - Use for this app: the "morning check-in" or alpha-feedback sound sessions could be written as
    `MEDITATION`/`MUSIC` sessions [inferred]. Low priority.
- **Device types** [verified] ([Device reference](https://developer.android.com/reference/kotlin/androidx/health/connect/client/records/metadata/Device)):
  `TYPE_UNKNOWN=0, WATCH=1, PHONE=2, SCALE=3, RING=4, HEAD_MOUNTED=5, FITNESS_BAND=6, CHEST_STRAP=7, SMART_DISPLAY=8`;
  extended types (need `FEATURE_EXTENDED_DEVICE_TYPES`, else treated as UNKNOWN): `CONSUMER_MEDICAL_DEVICE=9, GLASSES=10,
  HEARABLE=11, FITNESS_MACHINE=12, FITNESS_EQUIPMENT=13, PORTABLE_COMPUTER=14, METER=15`.
  **`TYPE_HEAD_MOUNTED` (5) is a base type, no feature flag**, and fits an EEG headband.
  `Device(type, manufacturer, model)`, e.g. `Device(TYPE_HEAD_MOUNTED, "BrainBit", "BrainBit Black")`.
- **Metadata / recording method** [verified] ([Metadata reference](https://developer.android.com/reference/kotlin/androidx/health/connect/client/records/metadata/Metadata),
  [metadata guide](https://developer.android.com/health-and-fitness/guides/health-connect/develop/metadata)):
  `RECORDING_METHOD_UNKNOWN=0, ACTIVELY_RECORDED=1, AUTOMATICALLY_RECORDED=2, MANUAL_ENTRY=3`; a device "must be specified"
  for actively/automatically recorded data. Factories: `Metadata.activelyRecorded(device, clientRecordId, clientRecordVersion = 0)`,
  `Metadata.autoRecorded(...)`, etc. A night the user starts with one tap is **actively recorded** ("The user initiated the start
  or end of the recording session on a device").
- **clientRecordId for idempotent re-writes** [verified]: "There is guaranteed a single entry for any type of data with same client
  provided identifier for a given client. Any new insertions with the same client provided identifier will either replace or be
  ignored depending on associated clientRecordVersion." "Data with the highest clientRecordVersion takes precedence"
  ([Metadata](https://developer.android.com/reference/kotlin/androidx/health/connect/client/records/metadata/Metadata),
  [sync guide](https://developer.android.com/health-and-fitness/guides/health-connect/develop/sync-data): "insertRecords ...
  existing data ... gets overwritten as long as the clientRecordId values exist ... and the clientRecordVersion is higher").
  Plan: `clientRecordId = "eeg_tracker:sleep:<session-uuid>"`, `clientRecordVersion = <scoring model version or unix ms of re-score>`,
  so re-scoring a night on the PC replaces the old hypnogram instead of adding a second session [inferred design].

### 2. Flutter packages

| Package | Latest (pub.dev API) | Published | Publisher | Licence (LICENSE file) | Notes |
|---|---|---|---|---|---|
| `health` | 13.3.2 | 2026-08-14 | carp.dk | MIT, "Copyright 2020 the Technical University of Denmark (DTU)" | 160/160 pub points, ~243k downloads/30 days; repo github.com/carp-dk/carp-health-flutter; uses `connect-client:1.2.0-alpha02`, Android `minSdkVersion 26`, `compileSdk 36` |
| `health_connector` | 3.14.1 | 2026-11-11 | phamtunglam.com | MIT, "Copyright (c) 2025 Pham Tung Lam" | 43 versions since 2025-11-23; Android part `health_connector_hc_android` 3.11.1 uses `connect-client 1.2.0-alpha03`, `minSdk = 26`; needs Dart SDK ^3.10, Flutter >= 3.38 |
| `flutter_health_connect` | 1.2.3 | 2023-03-08 | duynp.dev | not checked | unmaintained (no release for 3.5+ years) |

All [verified] from `https://pub.dev/api/packages/<name>`, `/publisher`, `/score`, and the 13.3.2 / 3.14.1 / 3.11.1 / 3.13.0 archives
(read only, not executed). Release cadence of `health` [verified, pub.dev versions]: 13.2.1 (2025-10-14), 13.3.0 (2026-01-25),
13.3.1 (2026-02-06), 13.3.2 (2026-08-14).

#### How `health` 13.3.2 maps the types (read from its source) [verified]

- `dataTypeKeysAndroid` in `lib/src/heath_data_types.dart` includes `HEART_RATE`, `HEART_RATE_VARIABILITY_RMSSD`, `RESTING_HEART_RATE`,
  `STEPS`, `WORKOUT`, `SLEEP_ASLEEP`, `SLEEP_AWAKE_IN_BED`, `SLEEP_AWAKE`, `SLEEP_DEEP`, `SLEEP_LIGHT`, `SLEEP_OUT_OF_BED`, `SLEEP_REM`,
  `SLEEP_SESSION`, `SLEEP_UNKNOWN`. **`MINDFULNESS` is iOS-only** (in `dataTypeKeysIOS`, not in the Android list; README table: Apple Health "yes", Health Connect blank).
- Stage mapping in `HealthDataWriter.kt`: `SLEEP_ASLEEP -> STAGE_TYPE_SLEEPING`, `SLEEP_LIGHT -> LIGHT`, `SLEEP_DEEP -> DEEP`, `SLEEP_REM -> REM`,
  `SLEEP_OUT_OF_BED -> OUT_OF_BED`, `SLEEP_AWAKE -> AWAKE`, `SLEEP_AWAKE_IN_BED -> AWAKE_IN_BED`, `SLEEP_UNKNOWN -> UNKNOWN`.
- **Limitation:** there is no `writeSleep` / multi-stage API. `writeHealthData(type: SLEEP_DEEP, ...)` calls `createSleepRecord(...)`, which
  builds a **separate `SleepSessionRecord` containing exactly one stage**; `SLEEP_SESSION` writes a session with no stages. So a
  scored night becomes dozens of one-stage "sleep sessions" plus an empty parent session. Other apps would likely show that as many short sleeps [inferred].
- Reading works well: for `SLEEP_*` types the reader walks `rec.stages` of every `SleepSessionRecord` (any app's) and returns one
  `HealthDataPoint` per matching stage; `HEART_RATE` returns one point per `HeartRateRecord` sample. Points carry `sourceName`, `sourceId`,
  `recordingMethod`, `deviceModel`, `uuid`.
- `writeHealthData({required double value, HealthDataUnit? unit, required HealthDataType type, required DateTime startTime, String? clientRecordId, double? clientRecordVersion, DateTime? endTime, RecordingMethod recordingMethod = RecordingMethod.automatic})`.
  clientRecordId is used only when **both** `clientRecordId` and `clientRecordVersion` are given. No device-type argument from Dart, so
  auto/active writes get `Device(type = TYPE_UNKNOWN)`.
- **Bug found:** Dart `RecordingMethod.toInt()` sends `active=1, manual=3` (matching Health Connect), but `HealthDataWriter.kt` defines
  `RECORDING_METHOD_MANUAL_ENTRY = 1` and `RECORDING_METHOD_ACTIVELY_RECORDED = 3`, so on Android `active` and `manual` are swapped when writing.
  `automatic` (2) and `unknown` (0) are correct. Use `RecordingMethod.automatic` with this package, or report the bug upstream.
- Other API: `requestAuthorization(types, permissions:)`, `isHealthDataHistoryAvailable/Authorized()`, `requestHealthDataHistoryAuthorization()`,
  `isHealthDataInBackgroundAvailable/Authorized()`, `requestHealthDataInBackgroundAuthorization()`, `getHealthDataFromTypes(types:, startTime:, endTime:)`,
  `deleteByClientRecordId(dataTypeKey:, clientRecordId:)`, `getHealthConnectSdkStatus()`, `installHealthConnect()`.
- README: the main activity must extend `FlutterFragmentActivity` (uses `registerForActivityResult`).

#### `health_connector` 3.14.1 [verified from source]

- `SleepSessionRecord({id, metadata, startTime, endTime, samples: List<SleepStageSample>, startZoneOffsetSeconds, endZoneOffsetSeconds, title, notes})`,
  one Health Connect record with many stages; validates 1 min <= duration <= 24 h. `SleepStageSample({startTime, endTime, stageType})` where
  `stageType` is `enum SleepStage { unknown, awake, sleeping, outOfBed, light, deep, rem, inBed }`. (Its README example writes `SleepStageType.light`;
  the actual enum is `SleepStage`, so use the source.)
- `Metadata.automaticallyRecorded({required Device device, String? clientRecordId, int? clientRecordVersion})` (and `activelyRecorded` etc.),
  `Device.fromType(DeviceType.headMounted)`; `DeviceType` includes `headMounted`.
- `HealthDataType.mindfulnessSession` (Android handler `MindfulnessSessionHandler` uses `MindfulnessSessionRecord`), `heartRateSeries`, `restingHeartRate`,
  `heartRateVariabilityRMSSD`, `steps`, `sleepSession`; `HealthPlatformFeature.readHealthDataHistory` / `readHealthDataInBackground`;
  `connector.getFeatureStatus(...)`, `requestPermissions([...readPermission, ...writePermission])`, `readRecords(type.readInTimeRange(startTime:, endTime:))`,
  `writeRecord(record)` / `writeRecords(records)`.
- Risk [inferred]: one maintainer and a young package (first release 2025-11-23) vs `health` backed by a university group. A third option is a
  ~100-line Kotlin method channel calling `connect-client` directly, which removes the dependency entirely.

**Pick [inferred]:** `health_connector` for writing the sleep session (and optional mindfulness); keep the write code in one small module so it
can be swapped for a Kotlin channel. Do not use `health` for writing sleep.

### 3. Permissions and manifest

Permissions this app would declare [verified names from the data types page and the `health` example manifest]:

```xml
<!-- read for correlation -->
<uses-permission android:name="android.permission.health.READ_SLEEP"/>
<uses-permission android:name="android.permission.health.READ_HEART_RATE"/>
<uses-permission android:name="android.permission.health.READ_RESTING_HEART_RATE"/>
<uses-permission android:name="android.permission.health.READ_HEART_RATE_VARIABILITY"/>
<uses-permission android:name="android.permission.health.READ_STEPS"/>
<uses-permission android:name="android.permission.health.READ_EXERCISE"/>
<uses-permission android:name="android.permission.health.READ_MINDFULNESS"/>
<!-- write the EEG result -->
<uses-permission android:name="android.permission.health.WRITE_SLEEP"/>
<uses-permission android:name="android.permission.health.WRITE_MINDFULNESS"/>  <!-- only if we write sessions -->
<!-- optional extras -->
<uses-permission android:name="android.permission.health.READ_HEALTH_DATA_HISTORY"/>
<uses-permission android:name="android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND"/>

<queries>
  <package android:name="com.google.android.apps.healthdata" />
</queries>

<application>
  <!-- Android 13 and lower: privacy policy / rationale screen -->
  <activity android:name=".PermissionsRationaleActivity" android:exported="true">
    <intent-filter>
      <action android:name="androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE" />
    </intent-filter>
  </activity>
  <!-- Android 14+: same screen through an alias -->
  <activity-alias
      android:name="ViewPermissionUsageActivity"
      android:exported="true"
      android:targetActivity=".PermissionsRationaleActivity"
      android:permission="android.permission.START_VIEW_PERMISSION_USAGE">
    <intent-filter>
      <action android:name="android.intent.action.VIEW_PERMISSION_USAGE" />
      <category android:name="android.intent.category.HEALTH_PERMISSIONS" />
    </intent-filter>
  </activity-alias>
</application>
```

- Rationale activity + alias, and the `<queries>` package entry: [verified] from
  [Get started](https://developer.android.com/health-and-fitness/guides/health-connect/develop/get-started) ("Your Android manifest needs to have an
  Activity that displays your app's privacy policy"; "The activity must display the same privacy policy you provide for your app in the Google Play Console").
  In Flutter, `targetActivity` can be `.MainActivity` and the app routes to its privacy page, as the `health` README/example does [verified].
  Optional onboarding activity (`androidx.health.ACTION_SHOW_ONBOARDING` / `android.health.connect.action.SHOW_ONBOARDING`) is also documented there [verified].
- Platform: "Starting Android 14 (API Level 34), Health Connect is part of the Android Framework ... no setup necessary"; Android 13 and lower need the
  Health Connect app from Play; settings path on 14+: Settings > Security and Privacy > Privacy Controls > Health Connect [verified, Get started].
  SDK supports API 26+ (connect-client 1.2.0-alpha05 lowered library minSdk to 24), Health Connect app itself needs Android 9+; connect-client 1.1.0+
  needs `compileSdk = 36` and AGP 8.9.1+ [verified, Get started + release notes]. Both Flutter packages set `minSdk 26` [verified].
- **History:** "By default, all applications can read data from Health Connect for up to 30 days prior to when any permission was first granted";
  more needs `PERMISSION_READ_HEALTH_DATA_HISTORY` (`android.permission.health.READ_HEALTH_DATA_HISTORY`), guarded by `FEATURE_READ_HEALTH_DATA_HISTORY`.
  Without it, a single-record read older than that fails and list/aggregate/changes reads silently omit older points [verified,
  [read data](https://developer.android.com/health-and-fitness/guides/health-connect/develop/read-data),
  [HealthPermission](https://developer.android.com/reference/kotlin/androidx/health/connect/client/permission/HealthPermission)].
  Reinstalling resets the window to 30 days before the new grant [verified, read data].
- **Background:** reads normally happen in the foreground; `android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND` (guarded by
  `FEATURE_READ_HEALTH_DATA_IN_BACKGROUND`) allows reads from e.g. a WorkManager job [verified, read data + feature availability page].
  For us: the nightly correlation pull can run when the user opens the app in the morning, so background reads are optional [inferred].
- Feature flags [verified, [feature availability](https://developer.android.com/health-and-fitness/guides/health-connect/develop/feature-availability)]:
  `FEATURE_MINDFULNESS_SESSION`, `FEATURE_READ_HEALTH_DATA_IN_BACKGROUND`, `FEATURE_READ_HEALTH_DATA_HISTORY`, `FEATURE_EXTENDED_DEVICE_TYPES`,
  `FEATURE_SKIN_TEMPERATURE`, `FEATURE_ACTIVITY_INTENSITY`, `FEATURE_PLANNED_EXERCISE`, `FEATURE_PERSONAL_HEALTH_RECORD`, `FEATURE_MATCHMAKING`.
  "users using the APK (on Android 13 and lower) can't use the system module features that are only available on devices running Android 14 or higher."
- Steps also want the runtime `android.permission.ACTIVITY_RECOGNITION` according to the `health` README [verified it says so; whether Health Connect
  reads truly need it is not verified].

### 4. Google Play policy

- [verified, [Publish your health app](https://developer.android.com/health-and-fitness/guides/health-connect/publish/request-access)]:
  Play publishing requires (a) the Data safety section, (b) the **Health apps declaration form** (Play Console > App content > Health apps), where you tick
  health features (relevant: "Sleep management"; "Stress management, relaxation, mental acuity") and justify **each** Health Connect data type;
  (c) the privacy policy on the Play listing must be the same one shown from the Health Connect privacy link; request only the minimum data types.
  This must be redone whenever an update uses a different set of data types.
- [inferred, from memory, support.google.com was unreachable]: Play's "Health Connect permissions" policy limits use to user-facing health features
  (sleep tracking is an allowed category), applies Limited Use rules (no selling, no ads use, no transfer except to provide the feature), and reviews
  background/history permissions separately.
- [inferred]: none of the Play forms apply to a sideloaded or F-Droid build. On Android 14+, Health Connect is a system module and grants permissions to
  any installed app that declares them and has the rationale activity; developers routinely test with `adb install`. On Android 13 and lower the user
  needs the Health Connect app, which comes from Play. The `connect-client` library is Apache-2.0 AndroidX code with no Google Play services dependency,
  so it should not block F-Droid inclusion (not checked against F-Droid's rules).
- Practical [inferred]: write a privacy policy page anyway (in-app, plus `docs/`), since Health Connect links to it on every device.

### 5. What to read and write for this app

Read (correlation; feeds the per-day export of DECISIONS.md row 12) [inferred design; types verified above]:
- Other apps' `SleepSessionRecord` (e.g. a watch or phone sleep app): compare total sleep time and wake times with the EEG hypnogram; this is also a cheap
  external check for DECISIONS.md row 8 (sleep model).
- `HeartRateRecord` during the night (from a watch/band), `RestingHeartRateRecord`, `HeartRateVariabilityRmssdRecord`: overnight HR dip and HRV as covariates.
- `StepsRecord` (daily total), `ExerciseSessionRecord` (late workouts), `MindfulnessSessionRecord` (meditation apps) as day-level factors.
- Filter out our own records via `dataOrigin` / `sourceId` so the app does not correlate with itself.

Write:
- One `SleepSessionRecord` per night: start/end = headband session, stages from the 30 s hypnogram with consecutive equal epochs merged,
  `title = "EEG sleep (eeg_tracker)"`, `notes` = model name/version and confidence, metadata `activelyRecorded(Device(TYPE_HEAD_MOUNTED, "BrainBit", "BrainBit Black"), clientRecordId, clientRecordVersion)`,
  zone offsets set (the `health` package always sends `null`).
- Write after the PC re-score as a new version with the same clientRecordId (higher version replaces) [verified mechanism].
- Optional: a `MindfulnessSessionRecord` for alpha-feedback sound sessions, only when `FEATURE_MINDFULNESS_SESSION` is available.
- Do not write HR/HRV/steps: the BrainBit has no such sensors.

### 6. Dart snippets (NOT RUN: no Dart/Flutter toolchain in this environment)

A. Using `health_connector` 3.14.1 (one session, many stages, stable ID). Signatures taken from the package source.

```dart
// NOT RUN. pubspec: health_connector: ^3.14.1
import 'package:health_connector/health_connector.dart';

/// stages: list of (start, end, stage) already merged from 30 s epochs.
Future<void> writeEegNight({
  required String sessionUuid,
  required int scoreVersion, // bump when the PC re-scores the night
  required DateTime start,
  required DateTime end,
  required List<({DateTime start, DateTime end, SleepStage stage})> stages,
}) async {
  final connector = await HealthConnector.create();
  final results = await connector.requestPermissions([
    HealthDataType.sleepSession.writePermission,
    HealthDataType.heartRateSeries.readPermission,
  ]);
  // check results before writing; the user may deny some permissions

  final record = SleepSessionRecord(
    id: HealthRecordId.none, // must be none for new records
    startTime: start,
    endTime: end,
    title: 'EEG sleep (eeg_tracker)',
    notes: 'AnySleep v? / YASA cross-check',
    samples: [
      for (final s in stages)
        SleepStageSample(startTime: s.start, endTime: s.end, stageType: s.stage),
    ],
    metadata: Metadata.activelyRecorded(
      device: Device.fromType(DeviceType.headMounted),
      clientRecordId: 'eeg_tracker:sleep:$sessionUuid',
      clientRecordVersion: scoreVersion,
    ),
  );
  await connector.writeRecord(record);

  // Read heart rate from other apps for the same night
  final hr = await connector.readRecords(
    HealthDataType.heartRateSeries.readInTimeRange(startTime: start, endTime: end),
  );
  for (final r in hr.records) {
    for (final s in r.samples) {
      print('${s.time} ${s.rate}');
    }
  }
  // hr.nextPageRequest != null -> more pages
}
```

(`Metadata.activelyRecorded` is assumed to have the same named parameters as the verified `Metadata.automaticallyRecorded`; use
`automaticallyRecorded` if it differs.)

B. Using `health` 13.3.2 (works today, but writes one record per stage; read path is fine).

```dart
// NOT RUN. pubspec: health: ^13.3.2 ; MainActivity must extend FlutterFragmentActivity
import 'package:health/health.dart';

final health = Health();

Future<void> demo(DateTime start, DateTime end,
    List<({DateTime start, DateTime end, HealthDataType type})> stages,
    String sessionUuid) async {
  await health.configure();
  final types = [HealthDataType.SLEEP_SESSION, HealthDataType.SLEEP_LIGHT,
                 HealthDataType.SLEEP_DEEP, HealthDataType.SLEEP_REM,
                 HealthDataType.SLEEP_AWAKE_IN_BED, HealthDataType.HEART_RATE];
  final ok = await health.requestAuthorization(types, permissions: [
    HealthDataAccess.READ_WRITE, HealthDataAccess.WRITE, HealthDataAccess.WRITE,
    HealthDataAccess.WRITE, HealthDataAccess.WRITE, HealthDataAccess.READ,
  ]);
  if (!ok) return;

  // Each call becomes its own SleepSessionRecord with ONE stage (package limitation).
  for (var i = 0; i < stages.length; i++) {
    final s = stages[i];
    await health.writeHealthData(
      value: 0, // ignored for sleep types
      type: s.type, // e.g. HealthDataType.SLEEP_DEEP
      startTime: s.start,
      endTime: s.end,
      clientRecordId: 'eeg_tracker:sleep:$sessionUuid:$i',
      clientRecordVersion: 1, // both id and version needed for the id to be used
      recordingMethod: RecordingMethod.automatic, // 'active' is swapped with 'manual' on Android in 13.3.2
    );
  }

  final hr = await health.getHealthDataFromTypes(
    types: [HealthDataType.HEART_RATE], startTime: start, endTime: end);
  for (final p in hr) {
    print('${p.dateFrom} ${(p.value as NumericHealthValue).numericValue} bpm from ${p.sourceName}');
  }
}
```

## Could not verify

- Google Play policy text (support.google.com pages for "Health Connect permissions" policy and the Health apps declaration help) — host blocked in this
  session; the Play section relies on the developer.android.com publish page plus memory.
- That a sideloaded/F-Droid APK gets Health Connect permissions on HyperOS Android 14 without issues (needs a test on the owner's phone).
- Whether the owner's phone has SDK extension level >= 15 (needed for mindfulness on Android 14): check `getFeatureStatus` on the device.
- How other apps (Google Fit successor, Xiaomi/Mi Fitness, Samsung Health) display one-stage sessions written by `health`, or whether Health Connect rejects overlapping sleep sessions from one app.
- GitHub repo activity, open issues and maintainer count for both Flutter packages (GitHub API not enabled for these repos in this session); maintenance judged from pub.dev release dates only.
- `health_connector`'s exact `Metadata.activelyRecorded` parameters and `HeartRateSample.rate` type (only `automaticallyRecorded` and the `time` field were read).
- Whether `ACTIVITY_RECOGNITION` is really needed to read steps through Health Connect.
- Neither Dart snippet was compiled or run (no Dart/Flutter SDK here).

## Sources (all accessed 2026-11-17)

- https://developer.android.com/reference/kotlin/androidx/health/connect/client/records/SleepSessionRecord
- https://developer.android.com/reference/kotlin/androidx/health/connect/client/records/MindfulnessSessionRecord
- https://developer.android.com/reference/android/health/connect/datatypes/MindfulnessSessionRecord
- https://developer.android.com/reference/kotlin/androidx/health/connect/client/records/metadata/Device
- https://developer.android.com/reference/kotlin/androidx/health/connect/client/records/metadata/Metadata
- https://developer.android.com/reference/kotlin/androidx/health/connect/client/permission/HealthPermission
- https://developer.android.com/health-and-fitness/guides/health-connect/develop/get-started
- https://developer.android.com/health-and-fitness/guides/health-connect/plan/data-types
- https://developer.android.com/health-and-fitness/guides/health-connect/develop/read-data
- https://developer.android.com/health-and-fitness/guides/health-connect/develop/write-data
- https://developer.android.com/health-and-fitness/guides/health-connect/develop/sync-data
- https://developer.android.com/health-and-fitness/guides/health-connect/develop/metadata
- https://developer.android.com/health-and-fitness/guides/health-connect/develop/feature-availability
- https://developer.android.com/health-and-fitness/guides/health-connect/develop/mindfulness
- https://developer.android.com/health-and-fitness/guides/health-connect/publish/request-access
- https://developer.android.com/jetpack/androidx/releases/health-connect
- https://pub.dev/api/packages/health (+ /publisher, /score, archive health-13.3.2.tar.gz: LICENSE, README.md, CHANGELOG.md, lib/src/*.dart, android/build.gradle, android/src/main/kotlin/cachet/plugins/health/*.kt, example AndroidManifest.xml)
- https://pub.dev/api/packages/health_connector (+ archives health_connector-3.14.1, health_connector_core-3.13.0, health_connector_hc_android-3.11.1)
- https://pub.dev/api/packages/flutter_health_connect
