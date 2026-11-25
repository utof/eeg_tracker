plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.github.utof.linkprobe.reader"
    compileSdk = 36

    defaultConfig {
        minSdk = 28
        targetSdk = 34 // the owner's phone runs Android 14
        versionCode = 1
        versionName = "1"
    }
    // "normal" is the reader the source trusts. "wrongkey" is the same code under another package id; build.py signs it with a
    // different key, and the source must refuse it on all three routes.
    flavorDimensions += "key"
    productFlavors {
        create("normal") {
            dimension = "key"
            applicationId = "io.github.utof.linkprobe.reader"
        }
        create("wrongkey") {
            dimension = "key"
            applicationId = "io.github.utof.linkprobe.readerwrong"
        }
    }
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
