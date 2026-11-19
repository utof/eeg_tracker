# neurosdk2 1.0.21, copied into the app

BrainBit's Flutter plugin `neurosdk2` 1.0.21 from pub.dev (BrainBit LLC, MIT licence, `LICENSE` kept), copied here on
2026-11-19 so that its calls stop running on Android's main thread (DECISIONS rows 410-413). The MIT licence allows
copying and changing it; the notice must travel with it.

## Why

In the sixth integration (2026-11-19) the app froze for good during a night without a headband: Android's main thread
sat inside BrainBit's native library (`Scanner.getSensors` -> `sensorsScanner`), called by the plugin's Pigeon
handler. The plugin answers every synchronous call from Dart (getSensors, getState, getBattPower, ...) on the main
thread, and Android hands it the Bluetooth scan results there too. Since Flutter 3.29 every Dart isolate of the process
runs on that same thread (the merged platform and UI threads; Flutter 3.47 cannot switch it off on Android), so one
native call that never returns froze the screen, the Stop button and the night recorder with its own deadline.

The two hangs seen on the emulator (arm64 build under the ARM translation, x86_64 API 36 image), shortened:

```
sixth integration, 2026-11-19 13:02, three dumps over 45 s alike ("isn't responding", Stop could not be tapped):
"main" prio=5 tid=1 Native  state=S
  at com.neurosdk2.neuro.Scanner.sensorsScanner(Native method)
  at com.neurosdk2.ScannerHolder.getSensors
  at com.neurosdk2.flutter_impl.Neurosdk2Plugin.getSensors
  at com.neurosdk2.PigeonMessages$NeuroApi.lambda$setUp$5
  at android.os.Looper.loop

same APK, a Java GC forced every 3 s (adb shell kill -10 <pid>), 13:46-13:50, two processes alike:
"pool-4-thread-1" prio=5 tid=19 Native  state=S
  native: #01 pc 0007b724  libc.so (pthread_join+228)
  at com.neurosdk2.neuro.Scanner.freeScanner(Native method)
  at com.neurosdk2.ScannerHolder.closeScanner
  at com.neurosdk2.flutter_impl.Neurosdk2Plugin.lambda$closeScanner$1  - locked <0x07854dfb> (mLocker)
"pool-4-thread-2" prio=5 tid=13 Blocked
  at com.neurosdk2.flutter_impl.Neurosdk2Plugin.lambda$createScanner$0
"pool-4-thread-1" prio=5 (not attached)     <- the library's own thread, named after the one that made it
  state=S schedstat=( 2963678 2994502 6 )   <- 6 context switches in all: waiting for good
"main" ... at android.os.MessageQueue.nativePollOnce   <- free, so the recorder's deadline restarted the process
```

## What changed (each place is marked `eeg_tracker change` in the source)

1. `android/src/main/java/com/neurosdk2/SdkLane.java` (new): one daemon thread per process, `neurosdk2-calls`, that
   runs in order what the main thread used to run. Scan results are dropped when 1000 already wait (only while the
   lane is stuck); calls from Dart never are.
2. `android/src/main/java/com/neurosdk2/LaneMessenger.java` (new): a `BinaryMessenger` that runs each incoming message
   on the lane. Flutter frees a message's bytes when the handler returns, so they are copied first.
3. `flutter_impl/Neurosdk2Plugin.java`, `onAttachedToEngine`: the Pigeon API (`PigeonMessages.NeuroApi.setUp`) is set
   up through `LaneMessenger`. The generated `PigeonMessages.java` is unchanged. The plugin's own executor for the
   asynchronous calls (scan start and stop, connect, commands) is unchanged.
4. `ble/BleScanCallback.java`: `onScanResult`, `onBatchScanResults` and `onScanFailed` hand their call into the native
   library to the lane (the task holds the callback object, so its `finalize()` cannot run before the task).
5. `pubspec.yaml`: Android only (the iOS, macOS, Windows and Linux parts and the example were not copied).
6. `android/build.gradle`: the unused Mockito test dependency removed (not on the laptop, and no test used it);
   `unitTests.returnDefaultValues = true` for the JVM tests below.
7. `android/src/test/java/com/neurosdk2/` (new): `SdkLaneTest` and `LaneMessengerTest` (the real Pigeon setup with an
   API whose getSensors blocks: the calling thread is back at once, the answers come later, in order).

Everything else is byte for byte the pub.dev package: the Dart side (`lib/`), the Pigeon source (`pigeons/`) and the
native libraries:

```
744cacbdf39e1796e99f48cd72fa5f63e458d2d1d1c98b5652f6c16ac8080613  android/src/main/jniLibs/arm64-v8a/libneurosdk2.so
2fc072cd587643bf2484677bc097bcd406edfc362a980f4fa05d852c8a5c3b13  android/src/main/jniLibs/armeabi-v7a/libneurosdk2.so
cee2a19f57182e330fa0821f22d6d807fef09bb019b1b204ac1cc101616cd489  android/src/main/jniLibs/x86_64/libneurosdk2.so
619c63ed65047d8289837637bf63895104674c23007e2e82807644d9bf67028e  android/src/main/jniLibs/x86/libneurosdk2.so
```

The release build still turns off this plugin's own shrinking (`app/android/build.gradle.kts`, DECISIONS row 58).

## Checking and upgrading

- Compare with the original: `diff -r ~/.pub-cache/hosted/pub.dev/neurosdk2-1.0.21/android packages/neurosdk2/android`
  (after `dart pub cache add neurosdk2 --version 1.0.21`) lists only the files above.
- The JVM tests, from `app/android` after one `flutter build apk` (it writes `gradlew` and `local.properties`):
  `./gradlew :neurosdk2:testDebugUnitTest`.
- A new BrainBit version: copy its `android/`, `lib/`, `pigeons/`, `LICENSE`, `CHANGELOG.md` and `README.md` over these,
  then apply changes 1-7 again (if the new version answers its calls off the main thread by itself, drop them).
