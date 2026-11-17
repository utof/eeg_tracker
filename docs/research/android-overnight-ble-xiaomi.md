# Keeping an 8-hour BrainBit recording alive on a Xiaomi 11T / 12T (HyperOS, Android 14)

Research note, 2026-11-17. Scope: a Flutter app records a BrainBit Black over Bluetooth LE (BrainBit's
`neurosdk2` plugin, 4 channels x 250 Hz) for about 8 hours with the screen off, on a Xiaomi 11T/12T running
HyperOS on Android 14, with targetSdk 34 or 35. Nothing here was run on a phone. All code is **not run**.

## Answer in 5 lines

1. Use one foreground service of type `connectedDevice` only. Do not add `dataSync`: on Android 15+ with targetSdk 35 it stops after 6 hours a day.
2. Use `flutter_foreground_task` 11.0.3 and run the whole BrainBit session (scan, connect, write to disk) inside its TaskHandler isolate. The neurosdk2 plugin gets a separate instance in each Flutter engine, so a sensor made in the UI isolate cannot be used from the service.
3. On the phone: Autostart on, Battery saver set to "No restrictions", app locked in Recents, Battery Saver/Ultra off. Test "Clear all" in Recents: on a Xiaomi 11T with HyperOS it was reported to kill this exact plugin's service.
4. On each start, the app checks battery optimization, background restriction, standby bucket, MIUI autostart (hidden API), and the exit reasons of the previous process. It also finds gaps in the data from `packNum` and timestamps.
5. Test plan: a 1-hour screen-off run with adb watching, then a "Clear all" test, then one full night. If the 1-hour run loses data, follow DECISIONS row 2 and switch to a native Kotlin recorder service.

## Evidence

### 1. Which foreground service type

- **[verified]** `connectedDevice` needs `FOREGROUND_SERVICE_CONNECTED_DEVICE` in the manifest and
  `FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE` in `startForeground()`. At runtime one of these must hold: a
  manifest permission such as `CHANGE_NETWORK_STATE`, or a granted `BLUETOOTH_CONNECT` / `BLUETOOTH_SCAN` /
  `BLUETOOTH_ADVERTISE` / `UWB_RANGING`, or a USB permission. Its stated use is "interactions with external
  devices that require a Bluetooth ... connection".
  ([fgs service-types](https://developer.android.com/develop/background-work/services/fgs/service-types))
- **[verified]** The BLE background guide says: "Start a foreground service with the connectedDevice type"
  to keep a connection alive. The alternative it gives is `CompanionDeviceService` with
  `REQUEST_COMPANION_RUN_IN_BACKGROUND` and `startObservingDevicePresence()`.
  ([BLE background](https://developer.android.com/develop/connectivity/bluetooth/ble/background))
- **[verified]** `dataSync` (and `mediaProcessing`) may run for "a total of 6 hours in a 24-hour period".
  After that the system calls `Service.onTimeout(int, int)`. The timer resets when the user brings the app to
  the foreground. This applies to apps that target Android 15 (API 35) or higher, running on Android 15 or higher.
  Test commands: `adb shell device_config put activity_manager data_sync_fgs_timeout_duration <ms>`.
  Since Android 15, `dataSync` also cannot be started from `BOOT_COMPLETED`.
  ([fgs timeout](https://developer.android.com/develop/background-work/services/fgs/timeout),
  [Android 15 behavior changes](https://developer.android.com/about/versions/15/behavior-changes-15))
  The phone runs Android 14 today, so the timeout does not apply yet. A HyperOS 2 update to Android 15
  (likely on the 12T, see Could not verify) would bring it in. Because an 8-hour night is longer than
  6 hours, **never use `dataSync` for the recorder.** The flutter_foreground_task README's example manifest
  uses `dataSync|remoteMessaging`. Do not copy that example.
- **[verified]** `health` needs `FOREGROUND_SERVICE_HEALTH` plus either the manifest permission
  `HIGH_SAMPLING_RATE_SENSORS` or one of `BODY_SENSORS` (API ≤ 35), `READ_HEART_RATE`, ... ,
  `ACTIVITY_RECOGNITION`. Its stated use is fitness apps "such as exercise trackers".
  (same service-types page)
  **[inferred]** `health` has no time limit and could technically be satisfied just by declaring
  `HIGH_SAMPLING_RATE_SENSORS`. The data comes from an external Bluetooth device, though, and that is
  `connectedDevice`'s stated use. Pick `connectedDevice` alone. Add `health` only if Play review asks for it.
- **[verified]** Android 14 throws `MissingForegroundServiceTypeException` when no type is declared, and
  `SecurityException` when the runtime prerequisites are not met.
  ([Android 14 fgs types required](https://developer.android.com/about/versions/14/changes/fgs-types-required))
- **[verified]** Starting a foreground service from the background (Android 12+) is allowed when "the user
  turns off battery optimizations for your app", for an exact alarm the user asked for, or for Companion Device
  Manager apps that hold `REQUEST_COMPANION_START_FOREGROUND_SERVICES_FROM_BACKGROUND` or
  `REQUEST_COMPANION_RUN_IN_BACKGROUND`. This matters for auto-restart after a kill.
  ([fgs background-start restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start))
- **[verified]** Since Android 14, users can swipe away "ongoing" foreground-service notifications, except
  while the phone is locked or with "Clear all". The service keeps running.
  ([Android 14 behavior changes](https://developer.android.com/about/versions/14/behavior-changes-all))

### 2. AndroidManifest entries (app `android/app/src/main/AndroidManifest.xml`)

Build these from the developer.android.com pages above and the plugin manifests below. **[verified]** for each
element's meaning. The combination has **not been built** yet.

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <!-- Foreground service (flutter_foreground_task's own manifest already adds
         FOREGROUND_SERVICE, WAKE_LOCK, RECEIVE_BOOT_COMPLETED, POST_NOTIFICATIONS) -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />

    <!-- Bluetooth, Android 12+ style -->
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN"
        android:usesPermissionFlags="neverForLocation" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <!-- legacy, Android 11 and lower only -->
    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"
        tools:replace="android:maxSdkVersion" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30"
        tools:replace="android:maxSdkVersion" />

    <!-- neurosdk2's manifest merges these in; we don't want them on Android 12+ -->
    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" tools:node="remove" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" tools:node="remove" />

    <!-- Only if the app is NOT on Google Play, or Play accepts it (see policy below) -->
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />

    <uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />

    <application ...>
        <!-- Name must stay exactly this (plugin README: "Do not change service name") -->
        <service
            android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
            android:foregroundServiceType="connectedDevice"
            android:exported="false" />
    </application>

    <!-- So resolveActivity() can see Xiaomi's settings apps on Android 11+ -->
    <queries>
        <package android:name="com.miui.securitycenter" />
        <package android:name="com.miui.powerkeeper" />
    </queries>
</manifest>
```

Notes:
- **[inferred]** The manifest merger is expected to accept `tools:replace="android:maxSdkVersion"` and
  `tools:node="remove"` on permissions that come from a library. Check the merged result after the first build in
  `build/app/intermediates/merged_manifests/release/AndroidManifest.xml` (or with Android Studio's "Merged Manifest" tab).
- **[verified]** `neverForLocation` on `BLUETOOTH_SCAN`, with `ACCESS_FINE_LOCATION` limited to
  `maxSdkVersion="30"`, is Google's documented pattern. Warning: "some BLE beacons are filtered from the scan
  results" when `neverForLocation` is set.
  ([Bluetooth permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions))
- **[verified]** neurosdk2 1.0.21's `android/src/main/AndroidManifest.xml` (pub.dev tarball) declares
  `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `ACCESS_BACKGROUND_LOCATION`,
  `BLUETOOTH (maxSdk 30)`, `BLUETOOTH_SCAN neverForLocation`, `BLUETOOTH_ADMIN` (no maxSdk) and
  `BLUETOOTH_CONNECT`. These merge into the app, so the app must remove the location permissions it does not
  want. BrainBit's own example still requests `Permission.location` at runtime.
  **[inferred]** On Android 12+, scanning with `neverForLocation` should not need location. If the
  BrainBit is not found after removing location, put `ACCESS_FINE_LOCATION` back without maxSdk and request it
  (test item T0 below).
- **[verified]** flutter_foreground_task 11.0.3's own manifest adds `FOREGROUND_SERVICE`, `WAKE_LOCK`,
  `RECEIVE_BOOT_COMPLETED`, `POST_NOTIFICATIONS` and two receivers (`RebootReceiver` for
  BOOT_COMPLETED / MY_PACKAGE_REPLACED / QUICKBOOT_POWERON, and `RestartReceiver`).
- **[verified]** You do not need `POST_NOTIFICATIONS` to *start* a foreground service. Without it, the
  notification is not shown in the drawer.
  ([notification permission](https://developer.android.com/develop/ui/views/notifications/notification-permission))
- **[verified] Play policy on `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`:** "Google Play policies prohibit apps
  from requesting direct exemption from Power Management features ... unless the core function of the app is
  adversely affected." The table of acceptable uses lists a "Peripheral device companion app" as acceptable
  only when its core function is "maintaining a persistent connection with the peripheral device for the
  purpose of providing the peripheral device internet access". Apps that "only need to connect to a peripheral
  device periodically to sync" are not acceptable.
  ([Doze and App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby))
  **[inferred]** Continuous overnight EEG streaming is not in the table. Doze does break its core function, so
  a case can be argued, but it is not certain. Decision: declare the permission in the GitHub/F-Droid build.
  If the app goes to Play, build a flavor without it that opens `Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS`
  instead. That intent needs no permission.
  ([Settings reference](https://developer.android.com/reference/android/provider/Settings))
- **[inferred]** Play also asks for a foreground-service type declaration, with a description and video, in
  Play Console. support.google.com was blocked from this session (see Could not verify).

### 3. flutter_foreground_task: version and setup

- **[verified]** Latest is **11.0.3**, published 2026-09-07 (pub.dev API). It needs Flutter ≥ 3.44, Dart
  ≥ 3.12, Kotlin 2.2.20+ and Gradle 8.11.1+. 10.0.0 needed Flutter 3.38, and 9.x supported Flutter 3.22+.
  If the project's Flutter is older, pin `^9.2.2`. The API used below is the same since 9.1
  (`serviceTypes` came in 9.1.0, `allowAutoRestart`/`stopWithTask` in 9.2.0).
  ([pub.dev API](https://pub.dev/api/packages/flutter_foreground_task), CHANGELOG in tarball)
- **[verified] From the source (11.0.3 tarball):**
  - `ForegroundTask` creates a **new `FlutterEngine(context)`** and runs the Dart `callback` in it. That
    constructor auto-registers every plugin, so the TaskHandler runs in a **separate isolate with its own
    plugin instances**.
  - `ForegroundService.startForeground(serviceId, notification, foregroundServiceTypes.value)`. The type value
    comes from `startService(serviceTypes: ...)`, or `FOREGROUND_SERVICE_TYPE_MANIFEST` if none is given.
  - `allowWakeLock` (default **true**) takes a `PARTIAL_WAKE_LOCK` tagged `"ForegroundService:WakeLock"` with
    **no timeout**, and releases it when the service stops.
  - `allowAutoRestart` (default **true** in the Dart constructor) sets an alarm 5 s ahead from `onDestroy()`
    when the service was not stopped by the app. `onTaskRemoved()` sets a 1 s restart alarm unless
    `stopWithTask` is set. That alarm uses `setAlarmClock` when exact alarms are allowed and `set(RTC_WAKEUP)`
    otherwise. `RestartReceiver` only logs a warning, and does not restart, on Android 12+ when the app is
    not exempt from battery optimization.
  - It overrides `onTimeout(startId)` and `onTimeout(startId, fgsType)`, stops itself, and passes
    `isTimeout=true` to `TaskHandler.onDestroy`.
  - It returns `START_STICKY` unless the stop-with-task flag is set.
- **[verified] neurosdk2 1.0.21 (pub.dev tarball):** `Neurosdk2Plugin implements FlutterPlugin` only. It is
  **not ActivityAware**, so it works in a headless engine. `onAttachedToEngine` makes a **new**
  `SensorHolder`, `ScannerHolder` and `EventHolder` for each engine. Event channels (signal, state, battery,
  resist) use `messenger.makeBackgroundTaskQueue()`. Dart: `Scanner.create([FSensorFamily.leBrainBitBlack])`,
  `scanner.sensorsStream`, `scanner.createSensor(info)` returns `BrainBitBlack`,
  `sensor.signalDataStream` gives `List<BrainBitSignalData>` with `packNum, marker, o1, o2, t3, t4`, and
  `sensor.execute(FSensorCommand.startSignal)`.
- **Consequence (correction to the brief) [verified from source + inferred]:** plugin callbacks arrive in
  *the isolate whose engine created the scanner/sensor*. They do not always arrive in the main isolate. A
  sensor created in the UI isolate cannot be used from the TaskHandler (different plugin instance, different
  GUID table), and the reverse is also true. Two designs:
  - **A (pick): everything in the TaskHandler isolate.** Scan, connect, `startSignal`, write chunks (dart:io
    works there) and run the heartbeat. The UI isolate only asks for permissions, starts and stops the service,
    and shows status from `sendDataToMain` (send about 1 message/s, not every sample).
    **[inferred]** The app keeps recording if HyperOS destroys the Activity. FlutterActivity destroys its own
    engine (and the main isolate) when the Activity is destroyed, unless a cached engine is used.
  - **B: BLE in the main isolate, service only as "keep-alive".** Simpler, but recording dies with the
    Activity's engine. This matches issue #340: "the actual background task has already been terminated"
    while the notification remains. Only use B with a `FlutterEngineCache`-held engine.
- **[verified]** `sendDataToMain` / `sendDataToTask` only carry primitives, String, List, Map, and Set
  (8.11+). Use JSON strings for anything else. `initCommunicationPort()` must be called in `main()`
  (`IsolateNameServer` port `_kPortName`).

Dart setup sketch (**not run**):

```dart
// pubspec: flutter_foreground_task: ^11.0.3, neurosdk2: ^1.0.21
import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:neurosdk2/neurosdk2.dart';

void main() {
  FlutterForegroundTask.initCommunicationPort();
  runApp(const App());
}

void initRecorderService() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'recording',
      channelName: 'Night recording',
      channelDescription: 'Shown while the headband is recording',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(10000), // heartbeat every 10 s
      autoRunOnBoot: false,          // a reboot ends the night; don't resurrect silently
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true,           // PARTIAL_WAKE_LOCK while recording (see section 4)
      allowWifiLock: false,
      allowAutoRestart: true,        // restart 1-5 s after a system kill (needs battery-opt exemption)
      stopWithTask: false,           // keep running when swiped from Recents
    ),
  );
}

Future<ServiceRequestResult> startRecording() =>
    FlutterForegroundTask.startService(
      serviceId: 4711,
      serviceTypes: [ForegroundServiceTypes.connectedDevice],
      notificationTitle: 'Recording EEG',
      notificationText: 'Headband connected',
      callback: recorderEntryPoint,
    );

@pragma('vm:entry-point')
void recorderEntryPoint() => FlutterForegroundTask.setTaskHandler(RecorderHandler());

class RecorderHandler extends TaskHandler {
  Scanner? _scanner;
  BrainBitBlack? _sensor;
  StreamSubscription? _sig;
  int? _lastPack;
  int _samples = 0, _gaps = 0;
  late DateTime _t0;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _t0 = timestamp;
    // starter == TaskStarter.system means: we were restarted after a kill -> log a gap marker.
    _scanner = await Scanner.create([FSensorFamily.leBrainBitBlack]);
    await _scanner!.start();
    final info = await _scanner!.sensorsStream.firstWhere((l) => l.isNotEmpty)
        .then((l) => l.first);
    await _scanner!.stop();
    _sensor = await _scanner!.createSensor(info) as BrainBitBlack;
    _sig = _sensor!.signalDataStream.listen((batch) {
      for (final s in batch) {
        if (_lastPack != null && s.packNum != _lastPack! + 1) _gaps++; // see wrap note in section 7
        _lastPack = s.packNum;
        _samples++;
        // append (s.o1, s.o2, s.t3, s.t4, wall-clock ms) to the current chunk file
      }
    });
    await _sensor!.execute(FSensorCommand.startSignal);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // heartbeat: write last-alive time to a small file, update notification, ping UI
    final expected = timestamp.difference(_t0).inMilliseconds * 250 ~/ 1000;
    FlutterForegroundTask.updateService(notificationText: '$_samples samples, $_gaps gaps');
    FlutterForegroundTask.sendDataToMain({'samples': _samples, 'expected': expected, 'gaps': _gaps});
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _sensor?.execute(FSensorCommand.stopSignal);
    await _sig?.cancel();
    await _sensor?.disconnect();
    // flush and close the chunk file; write "closed cleanly" marker
  }
}
```

### 4. Partial wake lock

- **[verified]** Google's decision tree: use a wake lock only if the work runs in a foreground service and it
  would hurt the user if the CPU suspended with the screen off. The wake lock must belong to a foreground service
  with its notification. Tag it with a fixed name.
  ([keep device awake](https://developer.android.com/develop/background-work/background-tasks/awake),
  [wake lock best practices](https://developer.android.com/develop/background-work/background-tasks/awake/wakelock/best-practices))
- **[verified]** Android vitals counts partial wake locks held "in the background or ... running a foreground
  service". It flags them as excessive at "2 or more hours in a 24-hour period". Audio, location and
  user-initiated JobScheduler wake locks are exempt.
  ([vitals: excessive wake locks](https://developer.android.com/topic/performance/vitals/wakelock))
  **[inferred, from a search summary of the 2026-03 Android Developers Blog post, which could not be opened]** Since
  2026-03-01, Play shows listing warnings or limits discovery for apps over that threshold.
  An overnight recorder will always be over it, which matters only if the app is on Play.
- **[inferred]** Decision: keep `allowWakeLock: true` *during a recording only*. The plugin releases it on
  stop. Losing EEG samples to CPU suspend or delayed Dart timers is worse than the battery cost. At 250 Hz the
  BLE link wakes the CPU very often anyway, so the extra cost should be small. Measure it in the 1-hour test
  (battery % per hour). Do not add a second, hand-made wake lock.

### 5. Xiaomi / HyperOS settings (user side)

- **[verified]** dontkillmyapp.com gives Xiaomi its worst score (`award: 5`). It says: "In default settings,
  background processing simply does not work right and apps using them will break". Its steps are:
  lock the app in Recents (drag the card down, or long-press and tap the padlock), or Security app → Boost
  speed → gear → Lock apps; "Background autostart" at *Settings > Apps > Your app > App permissions >
  Background autostart* (MIUI 14); *Security > Battery > App Battery Saver > your app > No restriction*;
  *Security app > Permissions > Auto-start*; "MIUI optimizations" in Developer options "can break the background
  tasks". (dontkillmyapp.com itself was blocked from this session. These lines were read from the site's source
  files: `_vendors/xiaomi.md` and `_vendors-content/xiaomi/{explanation,user,dev}.md` in
  [urbandroid-team/dont-kill-my-app](https://github.com/urbandroid-team/dont-kill-my-app).)
- **[verified]** AdGuard's knowledge base, section "MIUI 13+ and HyperOS", gives two variants. (1) *Settings → Apps →
  Permissions → Background autostart* allow; *Settings → Apps → Manage apps → [app]* uncheck **Pause app
  activity if unused**; **Battery saver → No restrictions**. (2) *Settings → Apps → Manage apps → [app]*
  enable **Autostart**; **Battery saver → No restrictions**.
  ([AdGuard KB source on GitHub](https://github.com/AdguardTeam/KnowledgeBase/blob/master/docs/adguard-for-android/solving-problems/background-work.md))

Checklist for the owner's phone (one-time). Run it in the app's "Night-ready check" screen:

| # | Setting | Path on HyperOS (Android 14) | Status |
|---|---|---|---|
| 1 | Notifications allowed (channel "Night recording" on) | Settings > Apps > Manage apps > eeg_tracker > Notifications | [verified] standard Android |
| 2 | Nearby devices (Bluetooth) allowed | ... > eeg_tracker > App permissions > Nearby devices | [verified] standard Android |
| 3 | **Autostart** on | Settings > Apps > Manage apps > eeg_tracker > Autostart (or Settings > Apps > Permissions > Background autostart) | [verified] AdGuard KB |
| 4 | **Battery saver: No restrictions** | Settings > Apps > Manage apps > eeg_tracker > Battery saver > No restrictions | [verified] AdGuard KB |
| 5 | Battery optimization off (Android allowlist) | Accept the app's system dialog, or Settings > Apps > Manage apps > ⋮ > Special app access > Battery optimization > All apps > eeg_tracker > Don't optimize | [inferred] menu wording |
| 6 | "Pause app activity if unused" off | Settings > Apps > Manage apps > eeg_tracker | [verified] AdGuard KB |
| 7 | **Lock in Recents** | Open Recents, long-press the eeg_tracker card (or drag it down), tap the padlock | [verified] dontkillmyapp |
| 8 | Battery Saver / Ultra battery saver **off** at night | Settings > Battery (on HyperOS 3 the page may be called "Power") | [inferred] search summaries |
| 9 | Charging overnight preferred | n/a | [inferred] Doze and HyperOS kill less while charging |
| 10 | Don't use "Clear all" (X) in Recents during a recording | n/a | [verified] issue #297, see section 6 |
| 11 | Security app > Battery > gear > "Clear cache/memory when device is locked" = Never (if present) | Security app | [inferred] MIUI-era option, not seen in a primary source |
| 12 | Developer options > "Turn on MIUI optimization" left as is (turning it off changes many things) | Developer options | [verified] dontkillmyapp mentions it; [inferred] advice not to touch |

Deep links to open these screens from the app (component names **[verified]** in the source of open-source
libraries; whether they still open on HyperOS 1/2 is **[inferred]**, so always wrap in try/catch and fall back
to `Settings.ACTION_APPLICATION_DETAILS_SETTINGS`):

| Screen | Intent | Seen in |
|---|---|---|
| Autostart list | component `com.miui.securitycenter/com.miui.permcenter.autostart.AutoStartManagementActivity` | AutoStarter `AutoStartPermissionHelper.kt`, auto_start_flutter 1.6.0, disable_battery_optimization 1.1.2, background_doctor 0.2.0 |
| Autostart (action) | `Intent("miui.intent.action.OP_AUTO_START").addCategory(CATEGORY_DEFAULT)` | autostart_settings 0.2.0 |
| Per-app battery saver ("No restrictions") | component `com.miui.powerkeeper/com.miui.powerkeeper.ui.HiddenAppsConfigActivity`, extras `package_name`, `package_label` | disable_battery_optimization 1.1.2 (it defines the extras' names but opens the screen without them) |
| Battery saver list (action) | `Intent("miui.intent.action.POWER_HIDE_MODE_APP_LIST")` | disable_battery_optimization (commented out) |
| Power settings | component `com.miui.securitycenter/com.miui.powercenter.PowerSettings` | auto_start_flutter 1.6.0 |
| Other permissions (MIUI 8+) | action `miui.intent.action.APP_PERM_EDITOR`, component `com.miui.securitycenter/com.miui.permcenter.permissions.PermissionsEditorActivity`, extra `extra_pkgname` | disable_battery_optimization (commented-out MIUI V8 code) |
| Android battery-opt dialog | `Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` + `package:` URI (needs the permission) | developer.android.com |
| Android battery-opt list | `Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS` (no permission) | developer.android.com |

**[verified]** background_doctor's README says that none of its vendor entries "has been verified on a real
device by this project". So treat the table as "try in order, then fall back".

### 6. Known HyperOS / MIUI problems (2024-2026)

- **[verified] "Clear all" kills the service on exactly this phone:** flutter_foreground_task issue
  [#297](https://github.com/Dev-hwang/flutter_foreground_task/issues/297) (2024-11-20, closed): on a
  "Xiaomi 11T with HyperOs and Android 14 ... when deleting all recent applications using the 'X' button, the
  service dies and does not start again automatically. However, if we slide the application to remove it
  from recent this does not happen." The comments could not be read. **[inferred]** Locking the app in Recents
  should protect it from "Clear all", because dontkillmyapp says locked apps are "not ... cleared from the
  background, even if you clear recent apps".
- **[verified]** Issue [#343](https://github.com/Dev-hwang/flutter_foreground_task/issues/343) (2025-05-05,
  closed as not planned): on Xiaomi/MIUI the service "is immediately killed when the user clears the app from the recent
  tasks list, even though a foreground notification is displayed". The reporter used it "for background BLE data
  collection" and had already turned off battery optimization.
- **[verified]** Issue [#340](https://github.com/Dev-hwang/flutter_foreground_task/issues/340) (2025-04-17,
  open, Android 15, device not stated): after a swipe-away, "the foreground service notification reappears ... but
  in reality, the service is no longer active". So the notification is not proof that recording is running.
  The data heartbeat (section 7) is the proof.
- **[verified]** Issue [#313](https://github.com/Dev-hwang/flutter_foreground_task/issues/313) (2024-12-31,
  open): notification buttons do not show on "Xiaomi HyperOs 1.0.13.0". Don't rely on a "Stop" button in the
  notification. Keep a Stop button in the app UI.
- **[verified]** HyperOS refuses foreground-service notifications whose custom view is too small
  (`BadForegroundServiceNotificationException: ... inflated notification does not meet minimum height
  requirement`), and that kills the service. Reported in
  [picassio/pi-phone#10](https://github.com/picassio/pi-phone/issues/10) (2026-11-12).
  **[inferred]** flutter_foreground_task builds a standard notification, so this should not affect us. Never
  switch to a custom `RemoteViews` notification.
- **[verified] Bluetooth scan throttling (stock Android, applies on HyperOS too):** "For unfiltered scans,
  scanning is stopped on screen off to save power." Use `ScanFilter`s for a scan that must run with the
  screen off.
  ([BluetoothLeScanner](https://developer.android.com/reference/android/bluetooth/le/BluetoothLeScanner))
  **[inferred]** `libneurosdk2.so` (arm64) contains `startScan(List, ScanSettings, ScanCallback)` and
  `setScanMode`, but no `ScanFilter` builder strings. It probably scans without filters. If so, **reconnecting
  after a dropout at 3 a.m. with the screen off may never find the headband.** Mitigation: on disconnect, retry
  `connect()` on the existing sensor object first (no new scan). Test this in T3. **[inferred]** Android also
  limits apps to about 5 `startScan` calls per 30 s (from memory, not checked this session), so don't
  re-scan in a tight loop.
- **[verified]** A third-party summary of an XDA thread ("HyperOS 3.0 CN instantly kills my background apps") says
  it "can't 100% fix" the behaviour. The thread itself could not be opened.
  **[inferred]** Forum reports that MIUI's memory cleaner kills services even with Autostart on
  (secondary source only).
- **[inferred]** No primary source was found for a HyperOS bug that targets `connectedDevice` services
  specifically, or for HyperOS limits on BLE *connections* (as opposed to scans).

### 7. Detecting from inside the app that the system restricted or killed it

APIs **[verified]** on developer.android.com:
- `PowerManager.isIgnoringBatteryOptimizations(String)` (API 23).
  ([PowerManager](https://developer.android.com/reference/android/os/PowerManager))
- `ActivityManager.isBackgroundRestricted()` (API 28): if true, "foreground services cannot be started unless an
  app activity is in the foreground".
  ([ActivityManager](https://developer.android.com/reference/android/app/ActivityManager))
- `UsageStatsManager.getAppStandbyBucket()` (API 28): ACTIVE=10, WORKING_SET=20, FREQUENT=30, RARE=40,
  RESTRICTED=45. An app in the active bucket is one that "runs a long running foreground service". Since Android 13, an
  app enters RESTRICTED after 8 days without use. Exempt from RESTRICTED: companion device apps, apps the user set to
  "unrestricted", and apps holding `USE_EXACT_ALARM` or `ACCESS_BACKGROUND_LOCATION`. adb: `adb shell am get-standby-bucket <pkg>`.
  ([UsageStatsManager](https://developer.android.com/reference/android/app/usage/UsageStatsManager),
  [App Standby buckets](https://developer.android.com/topic/performance/appstandby))
- `ActivityManager.getHistoricalProcessExitReasons(packageName, pid, maxNum)` (API 30), newest first, kept in a
  ring buffer. `ApplicationExitInfo.REASON_*`: UNKNOWN 0, EXIT_SELF 1, SIGNALED 2, LOW_MEMORY 3, CRASH 4,
  CRASH_NATIVE 5, ANR 6, INITIALIZATION_FAILURE 7, PERMISSION_CHANGE 8, EXCESSIVE_RESOURCE_USAGE 9,
  USER_REQUESTED 10 ("Force stop ... or removed the application away from Recents"), USER_STOPPED 11,
  DEPENDENCY_DIED 12, OTHER 13 ("getDescription() will specify the cause"), FREEZER 14 (API 33),
  PACKAGE_STATE_CHANGE 15 (API 34), PACKAGE_UPDATED 16 (API 34), MEMORY_LIMITER 17, ANOMALY 18. On devices
  that don't report it, a low-memory kill shows up as SIGNALED with status SIGKILL.
  Check with `isLowMemoryKillReportSupported()`.
  ([ApplicationExitInfo](https://developer.android.com/reference/android/app/ApplicationExitInfo))
  **[inferred]** HyperOS's own kills (PowerKeeper / "Clear all") most likely show up as `REASON_OTHER` with
  a vendor `description`, as `REASON_SIGNALED` (SIGKILL), or as `REASON_USER_REQUESTED`. Log the
  description and add it to this note after the first real kill.
- MIUI autostart state: there is no public API. **[verified]** XomaDev/MIUI-autostart (MIT, linked from
  dontkillmyapp's developer section) reflects `android.miui.AppOpsUtils.getApplicationAutoStart(Context, String)`.
  It returns 0 = enabled and 1 = disabled, and calls `HiddenApiBypass.addHiddenApiExemptions("")` first. Its README:
  hidden-API use may fail Play review, and it was tested only up to MIUI 14.0.2.
  ([Autostart.kt](https://github.com/XomaDev/MIUI-autostart/blob/master/library/src/main/kotlin/xyz/kumaraswamy/autostart/Autostart.kt))
  **[inferred]** Another method is MIUI's private AppOps op **10008** (`OP_AUTO_START`), read through
  `AppOpsManager.checkOpNoThrow(10008, uid, pkg)` by reflection. It is hidden too and was not checked on HyperOS. Both
  methods give "unknown" when they fail. Show "please check Autostart" in that case, and never report "OK".
- HyperOS version: **[verified]** background_doctor reads `ro.mi.os.version.name` (HyperOS, e.g. "OS1.0") and
  `ro.miui.ui.version.name` through the `getprop` command (no hidden API).

Kotlin checks (MethodChannel in `MainActivity`; **not run**):

```kotlin
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.app.usage.UsageStatsManager
import android.content.Context
import android.os.Build
import android.os.PowerManager

object PowerDiagnostics {
    fun snapshot(ctx: Context): Map<String, Any?> {
        val pm = ctx.getSystemService(PowerManager::class.java)
        val am = ctx.getSystemService(ActivityManager::class.java)
        val usm = ctx.getSystemService(UsageStatsManager::class.java)
        return mapOf(
            "ignoringBatteryOptimizations" to pm.isIgnoringBatteryOptimizations(ctx.packageName),
            "powerSaveMode" to pm.isPowerSaveMode,
            "deviceIdle" to pm.isDeviceIdleMode,
            "backgroundRestricted" to if (Build.VERSION.SDK_INT >= 28) am.isBackgroundRestricted else null,
            "standbyBucket" to if (Build.VERSION.SDK_INT >= 28) usm.appStandbyBucket else null, // 10/20/30/40/45
            "lowMemoryKillReportSupported" to
                if (Build.VERSION.SDK_INT >= 30) ActivityManager.isLowMemoryKillReportSupported() else null,
            "miuiAutostart" to miuiAutostart(ctx),          // "enabled" | "disabled" | "unknown"
            "hyperOs" to getprop("ro.mi.os.version.name"),
            "miui" to getprop("ro.miui.ui.version.name"),
        )
    }

    /** Exit records newer than [sinceMs] (store the session start time; call on next app start). */
    fun exitReasons(ctx: Context, sinceMs: Long): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < 30) return emptyList()
        val am = ctx.getSystemService(ActivityManager::class.java)
        return am.getHistoricalProcessExitReasons(ctx.packageName, 0, 20)
            .filter { it.timestamp >= sinceMs }
            .map {
                mapOf(
                    "timestamp" to it.timestamp, "reason" to it.reason, "status" to it.status,
                    "importance" to it.importance,   // 125 = foreground service
                    "description" to it.description, "processName" to it.processName,
                    "pssKb" to it.pss, "rssKb" to it.rss,
                )
            }
    }

    /** Hidden MIUI API, same call as XomaDev/MIUI-autostart. Without a hidden-API bypass it may be blocked. */
    private fun miuiAutostart(ctx: Context): String = try {
        val c = Class.forName("android.miui.AppOpsUtils")
        val m = c.getDeclaredMethod("getApplicationAutoStart", Context::class.java, String::class.java)
        m.isAccessible = true
        when (m.invoke(null, ctx, ctx.packageName) as? Int) { 0 -> "enabled"; 1 -> "disabled"; else -> "unknown" }
    } catch (t: Throwable) { "unknown" }

    private fun getprop(key: String): String? = try {
        val p = ProcessBuilder("getprop", key).redirectErrorStream(true).start()
        p.inputStream.bufferedReader().readText().trim().ifEmpty { null }.also { p.waitFor() }
    } catch (t: Throwable) { null }
}
```

Dart side (**not run**):

```dart
const _ch = MethodChannel('eeg_tracker/power');

Future<List<String>> nightReadyProblems() async {
  final s = Map<String, dynamic>.from(await _ch.invokeMethod('snapshot'));
  return [
    if (s['ignoringBatteryOptimizations'] != true) 'Battery optimization is on',
    if (s['backgroundRestricted'] == true) 'Background use is restricted',
    if ((s['standbyBucket'] ?? 10) > 10) 'Standby bucket ${s['standbyBucket']} (want 10 while recording)',
    if (s['powerSaveMode'] == true) 'Battery Saver is on',
    if (s['miuiAutostart'] != 'enabled' && (s['hyperOs'] ?? s['miui']) != null)
      'Autostart: ${s['miuiAutostart']} - please check it in settings',
  ];
}
```

Gap detection in the data (**[inferred]** design; the fields are **[verified]** in neurosdk2):
- For every sample, store `packNum` and the phone's wall-clock time of the batch. A gap is any `packNum` step ≠ +1,
  or a wall-clock jump > 100 ms between batches. The width at which `packNum` wraps is not documented (it is a
  Java `int` in `BrainBitSignalData`). Find it in T1 by logging the max value, then treat a step to 0 at that
  width as normal.
- Session summary: `expected = 250 × (end − start in s)`, `got = samples written`, list of gaps with start time and
  length. The heartbeat file (written every 10 s from `onRepeatEvent`) plus the "closed cleanly" marker tell a
  kill (heartbeat stops, no marker) apart from a BLE dropout (heartbeat continues, samples stop).
- On the next app start: if the last session has no "closed cleanly" marker, call `exitReasons(sessionStart)` and save
  the result next to the recording. It then goes into the BDF+ annotations when `to_bdf.py` converts the session.
- `TaskStarter.system` in `onStart` means the plugin's restart alarm brought the service back. Log it as a gap
  start.

### 8. Step-by-step test plan

Setup: USB debugging on, `adb` on the laptop, app built in release mode, headband on a head (or with known
contact), phone at > 50 % battery, **not charging** for T1–T3.

- **T0: permissions without location.** Fresh install with the manifest above. Grant Nearby devices and
  Notifications only. Does the scan find the BrainBit? If not, add location back (section 2) and note it here.
- **T1: 1 hour, screen off, on battery.**
  1. Do checklist items 1–8 (section 5). The app's "Night-ready check" shows no problems.
  2. Start recording from the UI. Check `adb shell dumpsys activity services <pkg>` shows
     `ForegroundService` with `isForeground=true` and type `connectedDevice`. Check `adb shell dumpsys power | grep -i ForegroundService:WakeLock`
     shows the wake lock.
  3. Press power (screen off), unplug USB (or leave it on but uncharged via `adb shell dumpsys battery unplug`).
  4. After 60 min: wake the phone and stop the recording. Expect `got ≥ 0.999 × expected`, 0 kills, and
     battery drop per hour noted.
  5. `adb shell am get-standby-bucket <pkg>` should be 10. Collect `adb logcat -b events -d | grep -i -E "am_kill|am_proc_died"`.
  **[inferred]** `adb shell dumpsys activity exit-info <pkg>` shows the same records as the API.
- **T2: forced Doze.** With a recording running and the screen off: `adb shell dumpsys deviceidle force-idle`, wait
  10 min, then `adb shell dumpsys deviceidle unforce` and `adb shell dumpsys battery reset`. Expect no gap.
  ([Doze testing](https://developer.android.com/training/monitoring-device-state/doze-standby))
- **T3: hostile actions, 5 min each.** (a) swipe the app away from Recents; (b) "Clear all" in Recents with
  the app **locked**; (c) "Clear all" with the app **unlocked** (expected to kill, per #297); (d) take the
  headband out of range for 60 s, then bring it back with the screen off (reconnect without a scan);
  (e) Bluetooth off/on. For each: is there a gap, and does the app recover by itself? Read
  `exitReasons` on the next start and record the `reason` and `description` HyperOS uses.
- **T4: full night.** Charging or not (do one of each over two nights), Do Not Disturb on, checklist done.
  Next morning: session summary (expected vs. got, gaps), exit reasons, battery used, BDF+ conversion with
  gap annotations. Pass: ≥ 99.5 % of expected samples and no gap > 60 s.
- **If T1 or T4 fails** after the checklist was followed: first try design B with a cached engine to rule out
  isolate problems. Then try `CompanionDeviceManager` association (exempt from the RESTRICTED bucket and from FGS
  start limits). Last, follow DECISIONS row 2: move the recorder into a native Kotlin foreground service that
  writes the chunk files itself, and keep Flutter for the UI only.

## Could not verify

- dontkillmyapp.com itself, its JSON API, xdaforums.com, medium.com, intercom.help, drivequant.com and
  support.google.com were blocked by the session's network proxy. Xiaomi steps come from the dontkillmyapp *source
  repo* and AdGuard's KB source on GitHub. Google Play's foreground-service declaration rules and
  its `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` review practice were not read first-hand.
- The comments on flutter_foreground_task issues #297/#343/#340 (session had no repo access, only search API bodies).
- Exact HyperOS 1/2/3 menu labels on the 11T/12T, and whether the `com.miui.*` deep-link activities and
  `android.miui.AppOpsUtils.getApplicationAutoStart` still exist on HyperOS. Also whether AppOps op 10008 is still
  the autostart op.
- Which Android version the owner's phone will get next. The 11T is believed to end at Android 14 and the 12T to
  receive Android 15 (HyperOS 2), from memory.
- Whether `libneurosdk2.so` really scans without `ScanFilter`s (string inspection only), and how `packNum` wraps.
- How HyperOS labels its own kills in `ApplicationExitInfo` (reason and description).
- The Android limit of about 5 scan starts per 30 s (from memory).
- The 2026-03 Play "battery technical quality enforcement" blog post (seen only as a search summary).
- Nothing was built or run on a phone. All code in this note is not run.

## Sources

All accessed 2026-11-17.

- https://pub.dev/api/packages/flutter_foreground_task and tarball `flutter_foreground_task-11.0.3.tar.gz` (README, CHANGELOG, `android/src/main/AndroidManifest.xml`, `service/ForegroundService.kt`, `ForegroundTask.kt`, `RestartReceiver.kt`, `models/ForegroundServiceTypes.kt`, `lib/flutter_foreground_task.dart`, `lib/models/foreground_task_options.dart`)
- https://pub.dev/api/packages/neurosdk2 and tarball `neurosdk2-1.0.21.tar.gz` (`android/src/main/AndroidManifest.xml`, `flutter_impl/Neurosdk2Plugin.java`, `EventHolder.java`, `ble/*.java`, `lib/scanner.dart`, `lib/sensor.dart`, `lib/brain_bit_black.dart`, `lib/pigeon_messages.g.dart`, string inspection of `jniLibs/arm64-v8a/libneurosdk2.so`)
- https://developer.android.com/develop/background-work/services/fgs/service-types
- https://developer.android.com/develop/background-work/services/fgs/timeout
- https://developer.android.com/develop/background-work/services/fgs/declare
- https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- https://developer.android.com/about/versions/14/changes/fgs-types-required
- https://developer.android.com/about/versions/14/behavior-changes-all
- https://developer.android.com/about/versions/15/behavior-changes-15
- https://developer.android.com/develop/connectivity/bluetooth/bt-permissions
- https://developer.android.com/develop/connectivity/bluetooth/ble/background
- https://developer.android.com/reference/android/bluetooth/le/BluetoothLeScanner
- https://developer.android.com/training/monitoring-device-state/doze-standby
- https://developer.android.com/topic/performance/appstandby
- https://developer.android.com/develop/background-work/background-tasks/awake
- https://developer.android.com/develop/background-work/background-tasks/awake/wakelock/set
- https://developer.android.com/develop/background-work/background-tasks/awake/wakelock/best-practices
- https://developer.android.com/topic/performance/vitals/wakelock
- https://developer.android.com/develop/ui/views/notifications/notification-permission
- https://developer.android.com/reference/android/app/ApplicationExitInfo
- https://developer.android.com/reference/android/app/ActivityManager
- https://developer.android.com/reference/android/app/usage/UsageStatsManager
- https://developer.android.com/reference/android/os/PowerManager
- https://developer.android.com/reference/android/provider/Settings
- https://github.com/urbandroid-team/dont-kill-my-app (`_vendors/xiaomi.md`, `_vendors-content/xiaomi/explanation.md`, `user.md`, `dev.md`, `_layouts/vendor.html`), the source of https://dontkillmyapp.com/xiaomi
- https://github.com/AdguardTeam/KnowledgeBase/blob/master/docs/adguard-for-android/solving-problems/background-work.md
- https://github.com/XomaDev/MIUI-autostart (README, `library/src/main/kotlin/xyz/kumaraswamy/autostart/Autostart.kt`)
- https://github.com/judemanutd/AutoStarter (`AutoStartPermissionHelper.kt`)
- pub.dev tarballs: `auto_start_flutter-1.6.0`, `autostart_settings-0.2.0`, `disable_battery_optimization-1.1.2`, `background_doctor-0.2.0` (README, `KnownOemIntents.kt`, `OemUiDetector.kt`, `BackgroundDoctor.kt`)
- https://github.com/Dev-hwang/flutter_foreground_task/issues/297, /343, /340, /313 (bodies via GitHub search API)
- https://github.com/picassio/pi-phone/issues/10 (body via GitHub search API)
- Search summaries only (not opened): https://xdaforums.com/t/hyperos-3-0-cn-instantly-kills-my-background-apps.4792408/, https://android-developers.googleblog.com/2026/03/battery-technical-quality-enforcement.html, https://llcloud.app/guides/stop-xiaomi-killing-apps/
