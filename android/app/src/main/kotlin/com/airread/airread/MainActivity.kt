package com.airread.airread

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "airread/local_llm"
    private val STREAM_CHANNEL = "airread/local_llm_stream"

    @Volatile
    private var streamSink: EventChannel.EventSink? = null

    @Volatile
    private var streamCancelled: Boolean = false

    companion object {
        private var nativeLibLoaded: Boolean = false
        init {
            try {
                try {
                    System.loadLibrary("MNN")
                } catch (_: UnsatisfiedLinkError) {}
                try {
                    System.loadLibrary("MNN_Express")
                } catch (_: UnsatisfiedLinkError) {}
                try {
                    System.loadLibrary("llm")
                } catch (_: UnsatisfiedLinkError) {}
                System.loadLibrary("mnn_bridge")
                nativeLibLoaded = true
            } catch (e: UnsatisfiedLinkError) {
                // Ignore if libraries are missing during dev without MNN
                println("Failed to load native libraries: $e")
                nativeLibLoaded = false
            }
        }
    }

    external fun nativeIsAvailable(): Boolean
    external fun nativeInit(modelPath: String)
    external fun nativeChat(prompt: String): String
    external fun nativeChatStream(prompt: String, callback: Any)

    private inner class LocalLlmStreamCallback {
        fun onChunk(text: String) {
            if (text.isEmpty()) return
            val sink = streamSink ?: return
            runOnUiThread { sink.success(mapOf("type" to "chunk", "data" to text)) }
        }

        fun onDone() {
            val sink = streamSink ?: return
            runOnUiThread { sink.success(mapOf("type" to "done")) }
        }

        fun onError(message: String) {
            val sink = streamSink ?: return
            runOnUiThread { sink.success(mapOf("type" to "error", "message" to message)) }
        }

        fun isCancelled(): Boolean {
            return streamCancelled
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, STREAM_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    streamSink = events
                }

                override fun onCancel(arguments: Any?) {
                    streamSink = null
                    streamCancelled = true
                }
            }
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> {
                    if (!nativeLibLoaded) {
                        result.error("NOT_AVAILABLE", "Native library not loaded", null)
                        return@setMethodCallHandler
                    }
                    try {
                        if (!nativeIsAvailable()) {
                            result.error("NOT_AVAILABLE", "Local LLM not enabled", null)
                            return@setMethodCallHandler
                        }
                    } catch (e: UnsatisfiedLinkError) {
                        result.error("NOT_AVAILABLE", "Local LLM not available", e.toString())
                        return@setMethodCallHandler
                    }
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
                    if (!nativeLibLoaded) {
                        result.error("NOT_AVAILABLE", "Native library not loaded", null)
                        return@setMethodCallHandler
                    }
                    try {
                        if (!nativeIsAvailable()) {
                            result.error("NOT_AVAILABLE", "Local LLM not enabled", null)
                            return@setMethodCallHandler
                        }
                    } catch (e: UnsatisfiedLinkError) {
                        result.error("NOT_AVAILABLE", "Local LLM not available", e.toString())
                        return@setMethodCallHandler
                    }
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
                "chatStream" -> {
                    if (!nativeLibLoaded) {
                        result.error("NOT_AVAILABLE", "Native library not loaded", null)
                        return@setMethodCallHandler
                    }
                    try {
                        if (!nativeIsAvailable()) {
                            result.error("NOT_AVAILABLE", "Local LLM not enabled", null)
                            return@setMethodCallHandler
                        }
                    } catch (e: UnsatisfiedLinkError) {
                        result.error("NOT_AVAILABLE", "Local LLM not available", e.toString())
                        return@setMethodCallHandler
                    }

                    val userText = call.argument<String>("userText")
                    if (userText == null) {
                        result.error("INVALID_ARG", "User text is null", null)
                        return@setMethodCallHandler
                    }
                    streamCancelled = false
                    val callback = LocalLlmStreamCallback()
                    Thread {
                        try {
                            nativeChatStream(userText, callback)
                        } catch (e: UnsatisfiedLinkError) {
                            callback.onError(e.toString())
                        } catch (e: Exception) {
                            callback.onError(e.toString())
                        }
                    }.start()
                    result.success(null)
                }
                "cancelChatStream" -> {
                    streamCancelled = true
                    result.success(null)
                }
                "isAvailable" -> {
                    if (!nativeLibLoaded) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(nativeIsAvailable())
                    } catch (e: UnsatisfiedLinkError) {
                        result.success(false)
                    }
                }
                "logcat" -> {
                    val tag = call.argument<String>("tag") ?: "AirRead"
                    val message = call.argument<String>("message") ?: ""
                    Log.i(tag, message)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
