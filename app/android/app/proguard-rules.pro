# ONNX Runtime's native library finds its Java classes by name (JNI), so R8 must keep them whole
# (flutter_onnxruntime's README, Android section). Without this a release build loads but fails at the first model.
-keep class ai.onnxruntime.** { *; }
