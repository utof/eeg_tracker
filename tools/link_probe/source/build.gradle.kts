plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// The reader's signing certificate, as a SHA-256 of 64 hex digits: build.py passes it (-PreaderSha256=...). The source refuses
// every caller whose certificate is not this one.
val readerSha256: String = (findProperty("readerSha256") as String?)?.trim()?.lowercase()
    ?: error("pass -PreaderSha256=<SHA-256 of the reader's certificate, 64 hex digits> (tools/link_probe/build.py does)")
require(Regex("[0-9a-f]{64}").matches(readerSha256)) { "readerSha256 must be 64 hex digits" }

android {
    namespace = "io.github.utof.linkprobe.source"
    compileSdk = 36

    defaultConfig {
        applicationId = "io.github.utof.linkprobe.source"
        minSdk = 28
        targetSdk = 34 // the owner's phone runs Android 14
        versionCode = 1
        versionName = "1"
        buildConfigField("String", "PINNED_READER_SHA256", "\"$readerSha256\"")
    }
    buildFeatures { buildConfig = true }
    lint { checkReleaseBuilds = false }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
