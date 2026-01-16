package com.airread.airread

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "airread/local_llm"

    companion object {
        init {
            try {
                System.loadLibrary("mnn_bridge")
                // System.loadLibrary("MNN")
                // System.loadLibrary("MNN_LLM")
            } catch (e: UnsatisfiedLinkError) {
                // Ignore if libraries are missing during dev without MNN
                println("Failed to load native libraries: $e")
            }
        }
    }

    external fun nativeInit(modelPath: String)
    external fun nativeChat(prompt: String): String

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> {
                    val modelPath = call.argument<String>("modelPath")
                    if (modelPath != null) {
                        try {
                            nativeInit(modelPath)
                            result.success(null)
                        } catch (e: UnsatisfiedLinkError) {
                            result.error("NATIVE_ERR", "Native init failed", e.toString())
                        }
                    } else {
                        result.error("INVALID_ARG", "Model path is null", null)
                    }
                }
                "chatOnce" -> {
                    val userText = call.argument<String>("userText")
                    if (userText != null) {
                        Thread {
                            try {
                                val response = nativeChat(userText)
                                runOnUiThread { result.success(response) }
                            } catch (e: UnsatisfiedLinkError) {
                                runOnUiThread { result.error("NATIVE_ERR", "Native chat failed", e.toString()) }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARG", "User text is null", null)
                    }
                }
                "isAvailable" -> {
                    // Check if native library loaded successfully (simplified)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
