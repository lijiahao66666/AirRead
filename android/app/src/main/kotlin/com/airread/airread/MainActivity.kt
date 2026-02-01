package com.airread.airread

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import androidx.annotation.Keep
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.Executors

class MainActivity: FlutterActivity() {
    private val CHANNEL = "airread/local_llm"
    private val STREAM_CHANNEL = "airread/local_llm_stream"
    private val TTS_CHANNEL = "airread/local_tts"
    private val TTS_STREAM_CHANNEL = "airread/local_tts_events"
    private val DEFAULT_MAX_NEW_TOKENS = 1024
    private val llmExecutor = Executors.newSingleThreadExecutor()

    @Volatile
    private var streamSink: EventChannel.EventSink? = null

    @Volatile
    private var streamCancelled: Boolean = false

    @Volatile
    private var ttsSink: EventChannel.EventSink? = null

    @Volatile
    private var ttsReady: Boolean = false

    @Volatile
    private var ttsInitInProgress: Boolean = false

    private var tts: TextToSpeech? = null
    private val ttsWaiters: MutableList<(Boolean, String?) -> Unit> = mutableListOf()

    private fun ensureTts(onReady: (Boolean, String?) -> Unit) {
        val existing = tts
        if (existing != null && ttsReady) {
            onReady(true, null)
            return
        }
        if (existing != null && !ttsReady) {
            try {
                existing.stop()
                existing.shutdown()
            } catch (_: Exception) {}
            tts = null
        }
        synchronized(ttsWaiters) {
            ttsWaiters.add(onReady)
        }
        if (ttsInitInProgress) {
            return
        }
        ttsInitInProgress = true
        val engineCandidates: List<String?> = run {
            val out = mutableListOf<String?>()
            out.add(null)
            try {
                val intent = Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE)
                val services = packageManager.queryIntentServices(intent, 0)
                for (s in services) {
                    val pkg = s.serviceInfo?.packageName ?: continue
                    if (!out.contains(pkg)) out.add(pkg)
                }
            } catch (_: Exception) {}
            out
        }

        fun notifyWaiters(ok: Boolean, err: String?) {
            ttsInitInProgress = false
            val waiters: List<(Boolean, String?) -> Unit>
            synchronized(ttsWaiters) {
                waiters = ttsWaiters.toList()
                ttsWaiters.clear()
            }
            for (w in waiters) {
                try {
                    w(ok, err)
                } catch (_: Exception) {}
            }
        }

        fun attachListener() {
            tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                private fun parseSession(id: String?): Int? {
                    if (id == null) return null
                    val prefix = "airread_tts_"
                    if (!id.startsWith(prefix)) return null
                    val rest = id.substring(prefix.length)
                    val parts = rest.split("_", limit = 2)
                    return parts.firstOrNull()?.toIntOrNull()
                }

                override fun onStart(utteranceId: String?) {}

                override fun onDone(utteranceId: String?) {
                    val session = parseSession(utteranceId)
                    val sink = ttsSink ?: return
                    runOnUiThread {
                        sink.success(mapOf("type" to "done", "session" to session))
                    }
                }

                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) {
                    val session = parseSession(utteranceId)
                    val sink = ttsSink ?: return
                    runOnUiThread {
                        sink.success(mapOf("type" to "error", "message" to "朗读失败", "session" to session))
                    }
                }

                override fun onError(utteranceId: String?, errorCode: Int) {
                    val session = parseSession(utteranceId)
                    val sink = ttsSink ?: return
                    val msg = when (errorCode) {
                        TextToSpeech.ERROR_INVALID_REQUEST -> "无效请求"
                        TextToSpeech.ERROR_NETWORK -> "网络错误"
                        TextToSpeech.ERROR_NETWORK_TIMEOUT -> "网络超时"
                        TextToSpeech.ERROR_NOT_INSTALLED_YET -> "语音包未安装"
                        TextToSpeech.ERROR_OUTPUT -> "输出错误"
                        TextToSpeech.ERROR_SERVICE -> "服务错误"
                        TextToSpeech.ERROR_SYNTHESIS -> "合成错误"
                        else -> "朗读失败($errorCode)"
                    }
                    runOnUiThread {
                        sink.success(mapOf("type" to "error", "message" to msg, "session" to session))
                    }
                }
            })
        }

        fun setupLanguage() {
            try {
                val locale = Locale.getDefault()
                val r = tts?.setLanguage(locale)
                if (r == TextToSpeech.LANG_MISSING_DATA || r == TextToSpeech.LANG_NOT_SUPPORTED) {
                    val r2 = tts?.setLanguage(Locale.CHINESE)
                    if (r2 == TextToSpeech.LANG_MISSING_DATA || r2 == TextToSpeech.LANG_NOT_SUPPORTED) {
                        tts?.setLanguage(Locale.ENGLISH)
                    }
                }
            } catch (_: Exception) {}
        }

        fun tryInitAt(index: Int) {
            if (index >= engineCandidates.size) {
                ttsReady = false
                Log.w("AirReadTts", "TTS init failed: no engine available")
                notifyWaiters(false, "本地朗读不可用（TTS初始化失败）")
                return
            }
            val enginePkg = engineCandidates[index]
            val listener = TextToSpeech.OnInitListener { status ->
                if (status == TextToSpeech.SUCCESS) {
                    ttsReady = true
                    setupLanguage()
                    attachListener()
                    notifyWaiters(true, null)
                    return@OnInitListener
                }
                ttsReady = false
                try {
                    tts?.stop()
                    tts?.shutdown()
                } catch (_: Exception) {}
                tts = null
                tryInitAt(index + 1)
            }
            try {
                tts = if (enginePkg != null &&
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP
                ) {
                    TextToSpeech(applicationContext, listener, enginePkg)
                } else {
                    TextToSpeech(applicationContext, listener)
                }
            } catch (_: Exception) {
                tts = null
                tryInitAt(index + 1)
            }
        }

        tryInitAt(0)
    }

    companion object {
        private var nativeLibLoaded: Boolean = false
        private var lastLoadError: String? = null

        init {
            try {
                Log.i("MainActivity", "Starting to load native libraries...")
                // 尝试加载库，即使部分失败也继续，只要 mnn_bridge 加载成功即可
                val libs = listOf(
                    "c++_shared", "mnncore", "MNN", "MNN_Express",
                    "MNNOpenCV", "MNN_CL", "MNN_Vulkan", "llm", "mnn_bridge"
                )

                for (lib in libs) {
                    try {
                        System.loadLibrary(lib)
                        Log.i("MainActivity", "Successfully loaded native library: $lib")
                        if (lib == "mnn_bridge") {
                            nativeLibLoaded = true
                        }
                    } catch (e: UnsatisfiedLinkError) {
                        val errMsg = "Failed to load native library $lib: ${e.message}"
                        Log.w("MainActivity", errMsg)
                        lastLoadError = errMsg
                    }
                }

                if (nativeLibLoaded) {
                    Log.i("MainActivity", "Native libraries (at least mnn_bridge) loaded successfully")
                } else {
                    Log.e("MainActivity", "Failed to load essential native library mnn_bridge. Last error: $lastLoadError")
                }
            } catch (e: Exception) {
                Log.e("MainActivity", "Unexpected error loading native libraries: $e")
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
    ): ByteArray?
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
        fun onChunk(data: ByteArray) {
            if (data.isEmpty()) return
            val sink = streamSink ?: return
            // 将字节数组传递给 Flutter，由 Flutter 处理解码，避免 JNI UTF-8 校验闪退
            runOnUiThread { sink.success(mapOf("type" to "chunk", "data" to data)) }
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
                    streamCancelled = false
                }

                override fun onCancel(arguments: Any?) {
                    streamSink = null
                    streamCancelled = true
                }
            }
        )

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, TTS_STREAM_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    ttsSink = events
                }

                override fun onCancel(arguments: Any?) {
                    ttsSink = null
                }
            }
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TTS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> {
                    val text = call.argument<String>("text") ?: ""
                    val rate = call.argument<Number>("rate")?.toFloat() ?: 1.0f
                    val session = call.argument<Int>("session") ?: 0
                    val lang = call.argument<String>("lang")
                    if (text.isBlank()) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    ensureTts { ok, err ->
                        if (!ok) {
                            result.error("NOT_AVAILABLE", err ?: "TTS not ready", null)
                            return@ensureTts
                        }
                        val engine = tts
                        if (engine == null) {
                            result.error("NOT_AVAILABLE", "TTS not ready", null)
                            return@ensureTts
                        }
                        try {
                            engine.stop()
                            if (lang != null && lang.isNotEmpty()) {
                                try {
                                    val loc = Locale.forLanguageTag(lang)
                                    val r = engine.setLanguage(loc)
                                    if (r == TextToSpeech.LANG_MISSING_DATA || r == TextToSpeech.LANG_NOT_SUPPORTED) {
                                        // Fallback to default if not supported
                                    }
                                } catch (_: Exception) {}
                            }
                            engine.setSpeechRate(rate.coerceIn(0.1f, 3.0f))
                            val params = Bundle()
                            params.putInt("session", session)
                            val utteranceId = "airread_tts_${session}_${System.currentTimeMillis()}"
                            engine.speak(text, TextToSpeech.QUEUE_FLUSH, params, utteranceId)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("NATIVE_ERR", "TTS speak failed", e.toString())
                        }
                    }
                }
                "stop" -> {
                    try {
                        tts?.stop()
                    } catch (_: Exception) {}
                    result.success(null)
                }
                "isAvailable" -> {
                    ensureTts { ok, _ ->
                        result.success(ok)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "init", "initialize" -> {
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
                            result.success(true)
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
                        val maxNewTokens = call.argument<Number>("maxNewTokens")?.toInt() ?: 128
                        val maxInputTokens = call.argument<Number>("maxInputTokens")?.toInt() ?: 512
                        val temperature = call.argument<Number>("temperature")?.toDouble() ?: 0.7
                        val topP = call.argument<Number>("topP")?.toDouble() ?: 0.9
                        val topK = call.argument<Number>("topK")?.toInt() ?: 40
                        val minP = call.argument<Number>("minP")?.toDouble() ?: 0.05
                        val presencePenalty = call.argument<Number>("presencePenalty")?.toDouble() ?: 0.0
                        val repetitionPenalty = call.argument<Number>("repetitionPenalty")?.toDouble() ?: 1.1
                        val enableThinking = if (call.argument<Boolean>("enableThinking") == true) 1 else 0
                        llmExecutor.execute {
                            try {
                                Log.i("MainActivity", "Calling nativeChat...")
                                val responseBytes = nativeChat(
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
                                Log.i("MainActivity", "nativeChat returned, bytes length: ${responseBytes?.size ?: 0}")
                                val response = responseBytes?.let { String(it, Charsets.UTF_8) }
                                Log.i("MainActivity", "Decoded response length: ${response?.length ?: 0}")
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
                    val maxNewTokens = call.argument<Number>("maxNewTokens")?.toInt() ?: 128
                    val maxInputTokens = call.argument<Number>("maxInputTokens")?.toInt() ?: 512
                    val temperature = call.argument<Number>("temperature")?.toDouble() ?: 0.7
                    val topP = call.argument<Number>("topP")?.toDouble() ?: 0.9
                    val topK = call.argument<Number>("topK")?.toInt() ?: 40
                    val minP = call.argument<Number>("minP")?.toDouble() ?: 0.05
                    val presencePenalty = call.argument<Number>("presencePenalty")?.toDouble() ?: 0.0
                    val repetitionPenalty = call.argument<Number>("repetitionPenalty")?.toDouble() ?: 1.1
                    val enableThinking = if (call.argument<Boolean>("enableThinking") == true) 1 else 0
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
                        Log.e("MainActivity", "nativeIsAvailable symbol not found: ${e.message}")
                        result.success(false)
                    }
                }
                "getNativeLoadError" -> {
                    result.success(lastLoadError)
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

    override fun onDestroy() {
        try {
            tts?.stop()
            tts?.shutdown()
        } catch (_: Exception) {}
        tts = null
        super.onDestroy()
    }
}
