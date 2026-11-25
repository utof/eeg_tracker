// The throw-away link probe (DECISIONS row 1020): two tiny apps, no Flutter. Same plugin versions as app/android, so a worker
// PC that has built the app already has them cached.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "link_probe"
include(":source", ":reader")
