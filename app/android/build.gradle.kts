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
// sherpa-onnx (the dream catcher's speech to text, DECISIONS row 251) ships its own ONNX Runtime 1.28.2 as
// libonnxruntime.so: the file name of flutter_onnxruntime's 1.28.0 (the sleep model), and each side asks for its
// own version's symbols (OrtGetApiBase@VERS_1.28.2 vs @VERS_1.28.0), so one file cannot serve both. sherpa-onnx's
// copy is packaged as libsherpa-ortx.so instead (a name of the same length, written into the library's own name
// and into libsherpa-onnx-c-api.so's list of needed libraries); the C++ wrapper library, unused from Dart, is left
// out. Both runtimes then load side by side.
subprojects {
    if (name.startsWith("sherpa_onnx_android_")) {
        afterEvaluate {
            val original = file("src/main/jniLibs")
            val renamed = layout.buildDirectory.dir("jniLibs-ort-renamed")
            val rename = tasks.register("renameSherpaOnnxRuntime") {
                inputs.dir(original)
                outputs.dir(renamed)
                doLast {
                    val from = "libonnxruntime.so".toByteArray()
                    val to = "libsherpa-ortx.so".toByteArray()
                    fun patched(bytes: ByteArray): ByteArray {
                        var i = 0
                        var n = 0
                        while (i <= bytes.size - from.size) {
                            if ((from.indices).all { bytes[i + it] == from[it] }) {
                                to.copyInto(bytes, i)
                                i += from.size
                                n++
                            } else {
                                i++
                            }
                        }
                        check(n > 0) { "no libonnxruntime.so in a sherpa-onnx library: the rename needs a look" }
                        return bytes
                    }
                    val out = renamed.get().asFile
                    out.deleteRecursively()
                    original.listFiles()!!.filter { it.isDirectory }.forEach { abi ->
                        val dir = File(out, abi.name).apply { mkdirs() }
                        File(dir, "libsherpa-ortx.so").writeBytes(patched(File(abi, "libonnxruntime.so").readBytes()))
                        File(dir, "libsherpa-onnx-c-api.so").writeBytes(patched(File(abi, "libsherpa-onnx-c-api.so").readBytes()))
                    }
                }
            }
            extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)
                ?.sourceSets?.getByName("main")?.jniLibs?.setSrcDirs(listOf(renamed))
            tasks.matching { it.name.startsWith("merge") && it.name.contains("JniLib") }.configureEach { dependsOn(rename) }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
