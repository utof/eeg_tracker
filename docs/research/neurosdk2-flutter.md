# BrainBit `neurosdk2` Flutter package (pub.dev 1.0.21): what it does and how to use it

## Answer in 5 lines

1. `neurosdk2` 1.0.21 (published 2025-12-09 by brainbit.com, MIT) is the latest version and supports BrainBit Black on Android, iOS, macOS and Windows. Linux is only an empty stub.
2. Flow: `Scanner.create([FSensorFamily.leBrainBitBlack])` → `start()` → `createSensor(info)` (this also connects) → `execute(startResist / startSignal)`. Data arrive on Dart streams: signal in volts, resistance in ohms, channels O1 O2 T3 T4.
3. On Android the plugin is plain Java with prebuilt `libneurosdk2.so` for 4 ABIs (16 KB-aligned): minSdk 21, compileSdk 34, no Kotlin, no Maven repo. Its manifest adds BLE and location permissions, including ACCESS_BACKGROUND_LOCATION.
4. The plugin does not start a foreground service or take a wakelock. Our app has to do that itself for overnight recording.
5. A Linux desktop target is possible: the Linux `.so` exports every C function the Windows C++ plugin calls. GitLab issue #58 is an open Windows build error, not a Linux or Android problem.

## Evidence

Package source: `https://pub.dev/api/archives/neurosdk2-1.0.21.tar.gz` (from `https://pub.dev/api/packages/neurosdk2`).
I downloaded and read it in the scratch dir. All paths below are relative to the package root. I did not build or run anything.

### Package facts, licence, changelog

- **[verified]** Latest version is 1.0.21, published 2025-12-09T08:07Z. 16 versions exist, from 1.0.6 (2024-07-02) to 1.0.21. Publisher is `brainbit.com`. pub points are 130/160. Platform tags: android, ios, windows, macos (no linux). Source: pub.dev API `/api/packages/neurosdk2`, `/score`, `/publisher`.
- **[verified]** `pubspec.yaml`:
  - Dart SDK `>=3.4.3 <4.0.0`, Flutter `>=3.22.0`.
  - Homepage `https://sdk.brainbit.com/`; issue tracker `https://gitlab.com/brainbit-inc/brainbit-sdk/-/issues`.
  - Plugin platforms: android (`com.neurosdk2.flutter_impl.Neurosdk2Plugin`), ios/macos (`sharedDarwinSource: true`), windows (`Neurosdk2PluginCApi`).
  - Linux is **commented out**: `# linux: pluginClass: Neurosdk2Plugin`.
  - No runtime dependencies besides Flutter. Dev dependencies: `pigeon ^25.3.2`, `flutter_lints ^6.0.0`, `meta`.
- **[verified]** `LICENSE` is the standard MIT text, "Copyright (c) 2025 BrainBit LLC". pub.dev tags it `license:mit`.
- **[inferred]** The MIT licence covers the wrapper code. The package also ships closed binaries (`android/src/main/jniLibs/*/libneurosdk2.so`, `windows/neuro_dll/neurosdk2-x64.dll`, `darwin/libneurosdk2.dylib`) under that same LICENSE file, so as shipped they are MIT-licensed too. This is BrainBit's own licensing choice. It is worth confirming with BrainBit before we redistribute the binaries outside an app build. DECISIONS #3 says "Core is a closed binary with no licence"; this package does give one.
- **[verified]** `CHANGELOG.md` highlights:
  - 1.0.8: Windows support added.
  - 1.0.12 and 1.0.14: iOS and macOS support.
  - 1.0.18: "Fixes multithreading functions".
  - 1.0.19: "Update android library for support 16 KB page sizes".
  - 1.0.20: iOS update.
  - 1.0.21: macOS binaries updated, plus "Added the ability to work with several types of devices at once".
  - No entry mentions Linux.

### Scanning

File: `lib/scanner.dart` (class `Scanner`). It calls the pigeon host API `NeuroApi` in `lib/pigeon_messages.g.dart`.

- **[verified]** Signatures:
  ```dart
  static Future<Scanner> create(List<FSensorFamily> filters);
  Stream<List<FSensorInfo>> get sensorsStream;      // event channel "event_neurosdk2/sensorListChanged"
  Future<void> start();                             // NeuroApi.startScan(guid)
  Future<void> stop();                              // NeuroApi.stopScan(guid)
  Future<List<FSensorInfo?>> getSensors();
  Future<Sensor?> createSensor(FSensorInfo sensorInfo);
  void dispose() async;                             // declared void: cannot be awaited; calls NeuroApi.closeScanner
  ```
- **[verified]** `enum FSensorFamily { leCallibri, leKolibri, leBrainBit, leBrainBitBlack, leBrainBit2, leBrainBitPro, leBrainBitFlex, unknown }`. BrainBit Black is `FSensorFamily.leBrainBitBlack`. `createSensor` returns a `BrainBitBlack` object for that family (switch in `lib/scanner.dart`).
- **[verified]** `FSensorInfo` fields: `String name, address, serialNumber; bool pairingRequired; int sensModel; FSensorFamily sensFamily; int rssi`.
- **[verified]** All streams are filtered by a GUID. Each stream wraps one global `EventChannel` broadcast stream and keeps only the events whose `guid` matches this object (`lib/event_channel_stream_wrapper.dart`).
- **[verified]** README: on a restarted scan, the callback fires only for new devices. Use `getSensors()` to get the full list.

### Creating and connecting a sensor; connection state; battery

Files: `lib/sensor.dart` (base class `Sensor`), `lib/brain_bit_sensor.dart` (`BrainBit extends Sensor`), `lib/brain_bit_black.dart` (`BrainBitBlack extends BrainBit with FPGSensor, MEMSSensor, AmpModeSensor, PingNeuroSmart`).

- **[verified]** README: "When created, the device is automatically connected." It also says creation "is a blocking method".
  - On Android, `createSensor` runs on a cached thread pool (`android/.../flutter_impl/Neurosdk2Plugin.java`), so the Dart `Future` simply completes after the connection.
  - **[verified 2026-11-19]** The other calls do not: every synchronous Pigeon method (`getSensors`, `getState`, `getBattPower`, the property reads and writes) runs its native call on Android's main thread, and Android hands the scan results (`ble/BleScanCallback.java`) to the native library there too. Since Flutter 3.29 all Dart runs on that thread, so a native call that never returns freezes the whole app; the emulator caught `Scanner.getSensors` doing so, and `Scanner.freeScanner` waiting for good on the library's own scan thread (`pthread_join`). The app now uses a copy of the plugin that moves that work to one thread of its own (`app/packages/neurosdk2/VENDORED.md`, DECISIONS rows 410-413).
  - Errors come back as `PlatformException`, e.g. "Cannot create sensor". README codes 107–110 cover create and connect failures.
- **[verified]** `Sensor` API:
  ```dart
  Stream<FSensorState> get sensorStateStream;   // "event_neurosdk2/connectionChanged", payload {'state': index}
  Stream<int> get batteryPowerStream;           // "event_neurosdk2/batteryChanged", payload {'power': int}
  late final SensorGetProperty<FSensorState> state;      // await sensor.state.value
  late final SensorGetProperty<int> batteryPower;        // await sensor.batteryPower.value
  // also: features, commands, parameters, serialNumber, samplingFrequency, firmwareMode,
  //       dataOffset, name (get/set), sensFamily, channelsCount, version, address, gain
  Future<void> connect();
  Future<void> disconnect();
  Future<void> close();                          // frees the native sensor
  Future<void> execute(FSensorCommand command);
  Future<bool> isSupportedFeature(FSensorFeature f);
  Future<bool> isSupportedCommand(FSensorCommand c);
  Future dispose();                              // cancels streams, then close()
  ```
  - `enum FSensorState { inRange, outOfRange }`.
  - The battery value is an int. The unit is undocumented; it is most likely a percentage.
- **[verified]** README warnings:
  - The state stream does **not** fire after creation. It fires only after a disconnect and a reconnect.
  - **"The device does not automatically reconnect."** For overnight recording, our app must watch for `outOfRange` and call `connect()` again itself.
- **[verified]** README: "BrainBitBlack, unlike BrainBit, requires pairing ... SDK starts the pairing process automatically." The Android native lib contains the string `createBond`, and `android/.../ble/BLEBroadcastReceiver.java` listens for `ACTION_BOND_STATE_CHANGED`.
  - **[inferred]** On Linux (DECISIONS) the Black connected without pairing. Android may show a system pairing dialog on first connect. This needs testing on the Xiaomi.

### Resistance (electrode contact)

- **[verified]** `BrainBit.resistDataStream` has type `Stream<BrainBitResistData>` (event channel `event_neurosdk2/resistanceChanged`).
  - `class BrainBitResistData { final double o1, o2, t3, t4; }` (`lib/cmn_types.dart`).
  - README table: values are "in Ohm".
  - README: "Initial resistance values are infinity. The values change when the BB is on the head."
- **[verified]** The README also says "For BrainBit the upper limit of resistance is 2.5 ohms."
  - **[inferred]** This is almost certainly a typo for kΩ or MΩ: real dry-electrode contact is in the kΩ–MΩ range. Calibrate thresholds from our own recordings.
- **[verified]** Start and stop with `execute(FSensorCommand.startResist)` / `stopResist`. `BrainBitBlack.samplingFrequencyResist` (type `SensorGetProperty<FSensorSamplingFrequency>`) reports the resistance update rate.
- **[verified]** In the C API, the resistance callback receives one struct per update, not an array: `void(*)(Sensor*, BrainBitResistData data, void*)` (Linux `sdk_api.h`). Struct: `double O1, O2, T3, T4`.

### Signal (EEG)

- **[verified]** `BrainBit.signalDataStream` has type `Stream<List<BrainBitSignalData>>` (event channel `event_neurosdk2/signalChanged`).
  - Each event is one native callback batch:
    ```dart
    class BrainBitSignalData { final int packNum; final int marker; final double o1, o2, t3, t4; }
    ```
  - The native struct (`windows/include/neurosdk2/cmn_type.h`, same on Linux) is `uint32_t PackNum; uint8_t Marker; double O1, O2, T3, T4;`.
  - Channel order is fixed by field name: O1, O2, T3, T4.
- **[verified]** README:
  - "The values come in volts"; table says "value of O1 channel in V".
  - 250 Hz, fixed for BrainBit and BrainBitBlack. Only gain can be changed.
  - "`PackNum` cannot be more then 2047", so it is an 11-bit counter that wraps.
  - The marker echoes `pingNeuroSmart(int marker)`, which is available on BrainBitBlack. The README says this is for checking signal quality and sync.
- **[verified]** README gives the ADC bit weight: `Wbit = (2*2.4) / ((2^21 - 1) * Gain)` volts (24-bit ADC with the last 3 bits dropped).
  - `BrainBit` overrides `gain` as `SensorGetSetProperty<FSensorGain>`, so gain is settable.
  - Allowed values for BrainBit: 1, 2, 3, 4, 6, 8, 12.
- **[inferred]** Store samples as V and convert to µV (×1e6) when writing BDF. That matches what pyneurosdk2 gives on the laptop. Samples per callback are not documented. Use `packNum` gaps (mod 2048) to detect lost BLE packets.
- **[verified]** On Android every callback is posted to the main thread: `mainThread.post(...)` in `android/.../BrainBitImpl.java`. The Dart listener therefore runs on the UI isolate. Keep the listener cheap: buffer, then write to disk in batches.

### Commands, disconnect, dispose

- **[verified]** `enum FSensorCommand` includes `startSignal, stopSignal, startResist, stopResist, startMEMS, stopMEMS, ..., startFPG, stopFPG, startSignalAndResist, stopSignalAndResist, ...`. Call them as `await sensor.execute(FSensorCommand.startSignal)`.
- **[verified]** `enum FSensorFeature { signal, mems, currentStimulator, respiration, resist, fpg, envelope, ..., signalWithResist }`. The example checks `isSupportedFeature(FSensorFeature.signal / resist)` before adding commands.
- **[verified]** BrainBitBlack also exposes:
  - `memsDataStream` (`List<MEMSData>`, accelerometer + gyroscope, 100 Hz per README)
  - `fpgStream` (`List<FPGData>`, IR/red amplitude)
  - `ampModeStream` (`FSensorAmpMode { invalid, powerDown, idle, signal, resist, signalResist, envelope }`)
  - `supportedChannels`, `amplifierParam`
  - In the Java layer, MEMS and FPG callbacks are registered only if the device reports those features. DECISIONS notes our Black reported no motion or pulse sensor.
- **[verified]** README shutdown order: `await sensor.disconnect(); sensor.dispose();`. `Sensor.dispose()` cancels the wrappers and then calls `close()`, which frees the native sensor. `Scanner.dispose()` returns `void` and cannot be awaited.
- **[verified]** Minor issues seen in the source:
  - `EventChannelStreamWrapper.dispose()` cancels the subscription but never closes the `StreamController`.
  - `BrainBitBlackImpl.java` calls `addCallbacks` twice: once through the super constructor's virtual call, once directly. Harmless, since it overwrites the same fields.

### Android build details

- **[verified]** `android/build.gradle`:
  - `com.android.library`, buildscript AGP `7.3.0`.
  - `namespace "com.neurosdk2.neurosdk2"`, set only if the property exists.
  - `compileSdk = 34`, `minSdk = 21`, Java 1.8 source/target.
  - Release `minifyEnabled true` with `consumerProguardFiles 'proguard-rules.pro'`.
  - Repositories: `google()` and `mavenCentral()` only. **No AAR and no private Maven repo.** The native code ships as `android/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86,x86_64}/libneurosdk2.so`.
- **[verified]** `android/proguard-rules.pro` is `-keep class com.neurosdk2.** { *; }`, and it is applied to consumers automatically. JNI callbacks rely on it, so the app needs no extra rules.
- **[verified]** No Kotlin in the plugin: all sources are Java. The example app uses Kotlin plugin 2.1.0 and NDK 26.1.10909125, but that is the example app's choice, not a requirement of the package.
- **[verified]** Native libs:
  - `readelf -l` shows LOAD alignment `0x4000` (16 KB) for arm64-v8a and x86_64, matching the 1.0.19 changelog.
  - The only NEEDED libs are `liblog, libm, libdl, libc`. The C++ runtime is linked in statically, so there is no `libc++_shared.so` conflict.
  - The lib finds the Android context itself: the strings `android/app/ActivityThread` and `currentActivityThread` appear in it.
- **[verified]** The plugin manifest (`android/src/main/AndroidManifest.xml`) is merged into our app:
  ```xml
  <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
  <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
  <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
  <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
  <uses-permission android:name="android.permission.BLUETOOTH_SCAN" tools:targetApi="31" android:usesPermissionFlags="neverForLocation"/>
  <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
  <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
  ```
  - The plugin does **not** request runtime permissions; `BleScanCallback` uses `@SuppressLint("MissingPermission")`.
  - The example app requests `bluetoothScan`, `bluetoothConnect` and `location` with `permission_handler ^12.0.1` before calling `Scanner.create`.
- **[inferred]** `ACCESS_BACKGROUND_LOCATION` arrives through manifest merge. If we never publish on Play, it is harmless. Otherwise remove it in our app manifest with `<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" tools:node="remove"/>`. We do not need location on Android 12+, because BLUETOOTH_SCAN has `neverForLocation`.
- **[verified]** Foreground service: `grep -rniE "Service|startForeground|wakelock|PowerManager|foreground"` over `android/src` finds only `ExecutorService` and BLE GATT `getService`/`onServicesDiscovered`. **The plugin starts no foreground service and takes no wakelock.** Background survival is left entirely to the app.
- **[inferred]** For Android 14 (HyperOS) overnight recording, the app must provide all of the following. This is from Android 14 rules, not from this package:
  - `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_CONNECTED_DEVICE` permissions
  - a `<service android:foregroundServiceType="connectedDevice">`
  - `POST_NOTIFICATIONS`
  - a battery-optimisation exemption
  - The plugin registers per FlutterEngine (`onAttachedToEngine` creates new holders). If the service runs a second engine (e.g. `flutter_foreground_task`), the SDK must be used from one engine only.

### Windows wiring

- **[verified]** This is a C++ MethodChannel/pigeon plugin, **not dart:ffi**. Relevant files: `windows/neurosdk2_plugin.cpp`, `windows/neurosdk2_plugin_c_api.cpp` with `Neurosdk2PluginCApiRegisterWithRegistrar`, and pigeon `windows/pigeon_messages/pigeon_messages.g.cpp`.
  - It implements `NeuroApi` plus 12 `flutter::EventChannel`s with the same names as on Android.
  - It calls the SDK's C API (`windows/include/neurosdk2/sdk_api.h`, `cmn_type.h`).
- **[verified]** `windows/CMakeLists.txt`:
  - Links at load time against the import library `neuro_dll/neurosdk2-x64.lib` (or `-x32`): `target_link_libraries(... ${LIB_NEURO})`.
  - Bundles the DLL through `set(neurosdk2_bundled_libraries ${NEUROLIB_DLL_PATH} PARENT_SCOPE)`. Shipped files: `neurosdk2-x64.dll`, `neurosdk2-x32.dll`.
  - No `LoadLibrary`/`GetProcAddress` calls are used.
- **[verified]** SDK callbacks call `EventHolder::GetInstance()->signalEventSink->Success(result)` directly from the SDK's thread, for example in `onBrainBitSignalDataReceived`.
  - **[inferred]** Flutter requires channel messages to be sent on the platform thread, so this can produce warnings or crashes on Windows. A Linux port should post to the GLib main loop instead (`g_idle_add`).

### Linux desktop target

- **[verified]** The package has a `linux/` dir, but it is only the `flutter create` template:
  - `linux/neurosdk2_plugin.cc` answers only `getPlatformVersion` on a `"neurosdk2"` channel.
  - `linux/CMakeLists.txt` sets `neurosdk2_bundled_libraries ""`.
  - The pubspec Linux entry is commented out.
- **[verified]** `github.com/BrainbitLLC/linux_neurosdk2` (shallow clone, HEAD `9f09ad4`, 2025-03-31, "Update Ubuntu package to v1.0.6.39. Added Headphones and Headband devices"). There are **no GitHub releases** listed (the API was blocked, so I cloned).
  - **[verified]** Repo files:
    - `raw_lib/libneurosdk2.so` and `raw_lib/headers/{sdk_api.h,cmn_type.h,lib_export.h}`
    - `raw_lib/dependencies/` (libc++.so.1, libc++abi.so.1, glib/gio, libudev, etc., built for AstraLinux, glibc 2.28)
    - `package/ubuntu24_04/libneurosdk2.deb`
    - `package/astra/libneurosdk2.deb`
  - **[verified]** README:
    - "Library compiled for AstraLinux v2.12.46 ... x86_64".
    - "We put the library dependencies next to the library itself".
    - Still says "Latest version: `1.0.6.29`" (stale).
    - Points to C++ samples at `gitlab.com/neurosdk2/neurosamples`.
  - **[verified]** The Ubuntu .deb `control` file:
    - `Version: 1.0.6.39-2cfe731`
    - `Depends: libudev1, libglib2.0-0 (>=2.72), libc6 (>=2.35), zlib1g, libc++-dev (>=1:14.0), libffi-dev, libbluetooth-dev, libusb-1.0-0-dev, libudev-dev, blueman`
    - Contents: `/usr/lib/libneurosdk2.so`, `/usr/include/libneurosdk2/*.h`
  - **[verified]** `readelf -d` on the deb's `.so`:
    - NEEDED = `libc++abi.so.1, libudev.so.1, libglib-2.0.so.0, libgio-2.0.so.0, libgobject-2.0.so.0, libm, libgcc_s, libc, ld-linux`. SONAME `libneurosdk2.so`.
    - No undefined `std::__1` symbols.
    - **[inferred]** So libc++ itself appears to be linked in statically. At runtime only `libc++abi.so.1`, and its own dependency `libunwind`, must be found. This is consistent with the project's `~/.local/lib/neurosdk2` setup.
- **[verified]** I extracted the C function names the Windows plugin calls (106 of them) and compared them with `nm -D` of both Linux `.so` files (raw_lib and deb 1.0.6.39). **All 106 are exported by both.** Example signatures from the Linux `sdk_api.h`:
  ```c
  SensorScanner* createScanner(SensorFamily* filters, int32_t szFilters, OpStatus* outStatus);
  uint8_t startScanner(SensorScanner* ptr, OpStatus* outStatus, int numOfTrying = 1);   // C++ default arg
  Sensor* createSensor(SensorScanner* ptr, SensorInfo sensor, OpStatus* outStatus);
  uint8_t execCommandSensor(Sensor* ptr, SensorCommand sensorCommand, OpStatus* outStatus);
  uint8_t addSignalDataCallbackBrainBit(Sensor* ptr, void(*callback)(Sensor*, BrainBitSignalData*, int32_t, void*), BrainBitSignalDataListenerHandle* handleOut, void* userData, OpStatus* outStatus);
  uint8_t addResistCallbackBrainBit(Sensor* ptr, void(*callback)(Sensor*, BrainBitResistData, void*), ...);
  ```
- **[inferred]** Two routes to a Linux target, plus a recommendation:
  - **(a) C++ plugin mirroring Windows (recommended for app parity).** Port `windows/neurosdk2_plugin.cpp` to the GObject/`flutter_linux` API. Pigeon can generate GObject code (`--gobject_*` outputs since pigeon 17), and the Dart side stays unchanged. Then:
    - uncomment `linux:` in a fork's pubspec
    - list `libneurosdk2.so` and `libc++abi.so.1` / `libunwind.so.1` in `neurosdk2_bundled_libraries` (Flutter copies them to `bundle/lib`, which is on the runner's RPATH `$ORIGIN/lib`)
    - marshal callbacks to the main loop with `g_idle_add`
    - About 2k lines, mostly mechanical. It needs a fork, because the package is BrainBit's.
  - **(b) dart:ffi binding.** Use `DynamicLibrary.open('libneurosdk2.so')` and `NativeCallable.listener` for the SDK-thread callbacks.
    - The headers need small fixes before ffigen (C++ default argument; `extern "C"` blocks).
    - It would bypass the Dart `Scanner`/`Sensor` classes, so it means a second API inside our app.
    - Simpler build, but the code diverges from Android.
  - **Bluetooth on Linux.** The `.so` uses GIO/glib (BlueZ over D-Bus). The user needs BlueZ running and must be in the group allowed to use it (default on desktop distros).
  - **Recommendation.** For the laptop, keep the existing Python path (pyneurosdk2 + the same `.so`) unless a Flutter desktop UI is wanted. If it is, use (a).

### GitLab issue #58

- **[verified]** GitLab API `https://gitlab.com/api/v4/projects/brainbit-inc%2Fbrainbit-sdk/issues/58` returned 200:
  - Title: **"neurosdk2 for flutter does not compile for Widnows device"**
  - State: **opened**. Created 2026-02-09T09:14Z, never updated, 0 comments, no labels.
  - Gist: MSVC errors `C2440: cannot convert from 'initializer list' to std::map<EncodableValue,EncodableValue>` at `windows/utils.cpp(51,28)`, `(66,28)`, `(80,28)`, in the Callibri signal, respiration and envelope converters. The reporter's workaround wraps `PackNum` in `EncodableValue(static_cast<int64_t>(...))` and builds an `EncodableList` instead of passing a raw `std::vector<double>`.
- **[verified]** The 1.0.21 `windows/utils.cpp` lines 44–70 still contain the failing code: `{flutter::EncodableValue("PackNum"), it.PackNum}` with `uint32_t`.
  - So the Windows build of 1.0.21 fails on that toolchain, even though only Callibri code is affected.
  - It does not affect Android, BrainBit Black data paths, or Linux.
  - Notes endpoint `/issues/58/notes` returned 401, so I could not read comments; the issue reports 0.

### Minimal Dart example (BrainBit Black). NOT RUN.

```dart
// NOT RUN. neurosdk2 1.0.21, permission_handler ^12.
import 'dart:async';
import 'package:neurosdk2/neurosdk2.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> recordBrainBitBlack() async {
  final perms = await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.location].request();
  if (!perms.values.every((s) => s.isGranted)) return;

  final scanner = await Scanner.create([FSensorFamily.leBrainBitBlack]);
  final found = Completer<FSensorInfo>();
  final scanSub = scanner.sensorsStream.listen((list) {
    if (list.isNotEmpty && !found.isCompleted) found.complete(list.first);
  });
  await scanner.start();
  final info = await found.future.timeout(const Duration(seconds: 20));
  await scanner.stop();
  await scanSub.cancel();

  // createSensor also connects (README). Black may trigger OS pairing on first use.
  final sensor = await scanner.createSensor(info) as BrainBitBlack;
  final stateSub = sensor.sensorStateStream.listen((s) async {
    if (s == FSensorState.outOfRange) {
      await sensor.connect(); // SDK does not auto-reconnect
    }
  });
  print('battery ${await sensor.batteryPower.value}, '
      'fs ${await sensor.samplingFrequency.value}'); // expect hz250

  // 1) Contact check: ohms, infinity when off-head.
  final resistSub = sensor.resistDataStream.listen((r) =>
      print('Ohm O1=${r.o1} O2=${r.o2} T3=${r.t3} T4=${r.t4}'));
  await sensor.execute(FSensorCommand.startResist);
  await Future.delayed(const Duration(seconds: 10));
  await sensor.execute(FSensorCommand.stopResist);
  await resistSub.cancel();

  // 2) EEG: volts, 250 Hz, packNum wraps at 2048.
  int? lastPack;
  final sigSub = sensor.signalDataStream.listen((batch) {
    for (final s in batch) {
      if (lastPack != null && s.packNum != (lastPack! + 1) % 2048) {
        print('gap: $lastPack -> ${s.packNum}');
      }
      lastPack = s.packNum;
      // store [s.o1, s.o2, s.t3, s.t4] * 1e6 as microvolts
    }
  });
  await sensor.execute(FSensorCommand.startSignal);
  await Future.delayed(const Duration(minutes: 1));
  await sensor.execute(FSensorCommand.stopSignal);
  await sigSub.cancel();

  await stateSub.cancel();
  await sensor.disconnect();
  await sensor.dispose();
  scanner.dispose();
}
```

## Could not verify

- Whether Android shows a pairing prompt for BrainBit Black. The README says pairing is required, but on Linux it worked without pairing.
- How many samples arrive per signal callback, and the exact unit of `batteryPower` (likely percent).
- The real meaning of "upper limit of resistance is 2.5 ohms" (very likely a unit typo).
- Whether the Windows callbacks' off-platform-thread `EventSink` calls cause crashes in practice. No Windows build was attempted.
- The `linux_neurosdk2` GitHub releases list. The GitHub API was blocked, so I cloned instead and saw no tags.
- Comments on GitLab issue #58 (notes endpoint returned 401; the issue says 0 comments).
- Whether BrainBit intends the MIT LICENSE to cover the bundled closed binaries.
- Android 14 foreground-service requirements are from memory of Android documentation, not re-checked this session.

## Sources (accessed 2026-11-17)

- https://pub.dev/api/packages/neurosdk2 (versions, archive_url), plus `/score` and `/publisher`
- https://pub.dev/api/archives/neurosdk2-1.0.21.tar.gz (package source, read locally: `pubspec.yaml`, `LICENSE`, `CHANGELOG.md`, `README.md`, `lib/*.dart`, `android/**`, `windows/**`, `linux/**`, `example/**`)
- https://github.com/BrainbitLLC/linux_neurosdk2 (git clone, commit 9f09ad459078042d7a93c116411d1c410ebf03b5; README, raw_lib headers and .so, `package/ubuntu24_04/libneurosdk2.deb` control and contents)
- https://gitlab.com/api/v4/projects/brainbit-inc%2Fbrainbit-sdk/issues/58 (issue JSON); web URL https://gitlab.com/brainbit-inc/brainbit-sdk/-/work_items/58
- https://gitlab.com/neurosdk2/neurosamples (referenced by linux_neurosdk2 README; not opened)
