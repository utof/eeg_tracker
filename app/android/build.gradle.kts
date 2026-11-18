allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// neurosdk2 1.0.21 shrinks its own release build (minifyEnabled true) without applying its keep rules to itself, so
// R8 strips Neurosdk2Plugin and the app's release build fails ("Missing class"). Build that one plugin unshrunk;
// the app's own R8 pass still applies the plugin's consumer keep rules. DECISIONS row 58.
subprojects {
    if (name == "neurosdk2") {
        afterEvaluate {
            extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)
                ?.buildTypes?.findByName("release")?.isMinifyEnabled = false
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
