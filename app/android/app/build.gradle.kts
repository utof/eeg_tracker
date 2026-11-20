plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.utof.eeg_tracker"
    // 37: permission_handler_android 14 (Android 17's local-network permission) refuses to build against less. This
    // only changes which Android APIs the code may call; the target (runtime behaviour) stays flutter.targetSdkVersion.
    compileSdk = maxOf(flutter.compileSdkVersion, 37)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.utof.eeg_tracker"
        // 26: notification channels and the power checks in PhoneChannel.kt need Android 8.
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Plugin libraries (ONNX Runtime, neurosdk2) come for every ABI; Flutter itself only for the one asked for.
        // When a build names its platform (`--target-platform android-arm64`, as for the owner's phone and CI),
        // package only that ABI: ONNX Runtime alone is 29 MB per ABI.
        val abis = mapOf(
            "android-arm" to "armeabi-v7a",
            "android-arm64" to "arm64-v8a",
            "android-x64" to "x86_64",
            "android-x86" to "x86",
        )
        (project.findProperty("target-platform") as String?)?.split(",")?.mapNotNull { abis[it.trim()] }
            ?.takeIf { it.isNotEmpty() }
            ?.let {
                ndk {
                    abiFilters.clear() // the Flutter plugin has already put all three of its ABIs here
                    abiFilters += it
                }
            }
    }

    // Compress native libraries in the APK (Android unpacks them at install): the APK is about half the size
    // to copy to the phone, at the cost of about 50 MB more on the phone after install.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // Debug keys for now (first phone tests); a real key comes with the first public release.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    // the JVM tests of the pure Kotlin parts (src/test: WifiFactsTest, DECISIONS 612)
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
