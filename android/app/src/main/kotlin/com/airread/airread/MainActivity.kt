package com.airread.airread

import android.util.Log
import androidx.annotation.Keep
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity: FlutterActivity() {
    private val CHANNEL = "airread/local_llm"
    private val STREAM_CHANNEL = "airread/local_llm_stream"
    private val DEFAULT_MAX_NEW_TOKENS = 1024
    private val llmExecutor = Executors.newSingleThreadExecutor()

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
    external fun nativeDumpConfig(): String
    external fun nativeChat(
        prompt: String,
        maxNewTokens: Int,
        maxInputTokens: Int,
        temperature: Double,
        topP: Double,
        topK: Int,
        minP: Double,
        presencePenalty: Double,
        repetitionPenalty: Double,
        enableThinking: Int
    ): String
    external fun nativeChatStream(
        prompt: String,
        maxNewTokens: Int,
        maxInputTokens: Int,
        temperature: Double,
        topP: Double,
        topK: Int,
        minP: Double,
        presencePenalty: Double,
        repetitionPenalty: Double,
        enableThinking: Int,
        callback: Any
    )

    @Keep
    inner class LocalLlmStreamCallback {
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
                        val maxNewTokens = call.argument<Int>("maxNewTokens") ?: DEFAULT_MAX_NEW_TOKENS
                        val maxInputTokens = call.argument<Int>("maxInputTokens") ?: 0
                        val temperature = call.argument<Number>("temperature")?.toDouble() ?: -1.0
                        val topP = call.argument<Number>("top_p")?.toDouble() ?: -1.0
                        val topK = call.argument<Number>("top_k")?.toInt() ?: -1
                        val minP = call.argument<Number>("min_p")?.toDouble() ?: -1.0
                        val presencePenalty = call.argument<Number>("presence_penalty")?.toDouble() ?: -1.0
                        val repetitionPenalty = call.argument<Number>("repetition_penalty")?.toDouble() ?: -1.0
                        val enableThinking = call.argument<Boolean>("enable_thinking")?.let { if (it) 1 else 0 } ?: -1
                        llmExecutor.execute {
                            try {
                                val response = nativeChat(
                                    userText,
                                    maxNewTokens,
                                    maxInputTokens,
                                    temperature,
                                    topP,
                                    topK,
                                    minP,
                                    presencePenalty,
                                    repetitionPenalty,
                                    enableThinking
                                )
                                runOnUiThread { result.success(response) }
                            } catch (e: UnsatisfiedLinkError) {
                                runOnUiThread { result.error("NATIVE_ERR", "Native chat failed", e.toString()) }
                            }
                        }
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
                    val maxNewTokens = call.argument<Int>("maxNewTokens") ?: DEFAULT_MAX_NEW_TOKENS
                    val maxInputTokens = call.argument<Int>("maxInputTokens") ?: 0
                    val temperature = call.argument<Number>("temperature")?.toDouble() ?: -1.0
                    val topP = call.argument<Number>("top_p")?.toDouble() ?: -1.0
                    val topK = call.argument<Number>("top_k")?.toInt() ?: -1
                    val minP = call.argument<Number>("min_p")?.toDouble() ?: -1.0
                    val presencePenalty = call.argument<Number>("presence_penalty")?.toDouble() ?: -1.0
                    val repetitionPenalty = call.argument<Number>("repetition_penalty")?.toDouble() ?: -1.0
                    val enableThinking = call.argument<Boolean>("enable_thinking")?.let { if (it) 1 else 0 } ?: -1
                    streamCancelled = false
                    val callback = LocalLlmStreamCallback()
                    llmExecutor.execute {
                        try {
                            nativeChatStream(
                                userText,
                                maxNewTokens,
                                maxInputTokens,
                                temperature,
                                topP,
                                topK,
                                minP,
                                presencePenalty,
                                repetitionPenalty,
                                enableThinking,
                                callback
                            )
                        } catch (e: UnsatisfiedLinkError) {
                            callback.onError(e.toString())
                        } catch (e: Exception) {
                            callback.onError(e.toString())
                        }
                    }
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
                "dumpConfig" -> {
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
                    llmExecutor.execute {
                        try {
                            val cfg = nativeDumpConfig()
                            runOnUiThread { result.success(cfg) }
                        } catch (e: UnsatisfiedLinkError) {
                            runOnUiThread { result.error("NATIVE_ERR", "Native dumpConfig failed", e.toString()) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("NATIVE_ERR", "Native dumpConfig failed", e.toString()) }
                        }
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
