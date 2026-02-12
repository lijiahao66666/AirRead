#include <jni.h>
#include <android/log.h>
#include <string>
#include <memory>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <queue>
#include <functional>
#include <sstream>
#include <iostream>
#include <vector>
#include <algorithm>
#include <fstream>
#include <cctype>

#define LOG_TAG "MNNBridgeReal"

// 在 Release 模式下禁用 LOGI，保留 LOGE
// Android NDK 的 CMake 构建通常会在 Release 模式定义 NDEBUG
#if defined(NDEBUG)
    #define LOGI(...) ((void)0)
#else
    #define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#endif

#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

#include <MNN/llm/llm.hpp>

// 自定义 ostream 以捕获 MNN 的输出
class JNIStringStream : public std::stringbuf {
public:
    std::string get_content() { return str(); }
};

// LLM 实例管理
static std::unique_ptr<MNN::Transformer::Llm> g_llm;
static std::mutex g_mutex;
static bool g_initialized = false;
static std::string g_model_config_path_for_log;

static std::string arTrimAscii(const std::string& s) {
    if (s.empty()) return s;
    const char* ws = " \n\r\t";
    const auto start = s.find_first_not_of(ws);
    if (start == std::string::npos) return "";
    const auto end = s.find_last_not_of(ws);
    return s.substr(start, end - start + 1);
}

static std::string arTail(const std::string& s, size_t maxLen) {
    if (maxLen == 0) return "";
    if (s.size() <= maxLen) return s;
    return s.substr(s.size() - maxLen);
}

static const int kMaxInputTokens = 4096;
static const int kMaxNewTokens = 1024;

static bool arLooksMeaningfulUtf8(const std::string& s) {
    const std::string t = arTrimAscii(s);
    if (t.empty()) return false;
    if (t.rfind("Error:", 0) == 0) return false;
    if (t.rfind("[错误]", 0) == 0) return false;
    if (t.rfind("错误:", 0) == 0) return false;
    if (t.rfind("错误：", 0) == 0) return false;
    for (size_t i = 0; i < t.size(); i++) {
        const unsigned char c = (unsigned char)t[i];
        if (std::isalnum(c)) return true;
        if (c >= 0xE4 && c <= 0xE9) return true;
    }
    return false;
}

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_airread_airread_MainActivity_nativeIsAvailable(JNIEnv *env, jobject thiz) {
    LOGI("nativeIsAvailable called");
    return JNI_TRUE;
}

JNIEXPORT void JNICALL
Java_com_airread_airread_MainActivity_nativeInit(JNIEnv *env, jobject thiz, jstring modelPath) {
    const char *path = env->GetStringUTFChars(modelPath, nullptr);
    LOGI("nativeInit called with model path: %s", path);
    
    std::lock_guard<std::mutex> lock(g_mutex);
    
    std::string pathStr = path;
    if (!pathStr.empty() && pathStr.back() != '/' && pathStr.back() != '\\') {
        pathStr += "/";
    }
    
    // 优先检查是否存在 config.json，如果存在则使用它作为配置文件路径
    std::string configPath = pathStr + "config.json";
    
    // 注意：不再在磁盘上解码 tokenizer.txt，因为这会破坏文件格式（空格/换行问题）
    // MNN 的 LLM 引擎在加载时会自动处理 Base64 编码的 tokens

    FILE* f = fopen(configPath.c_str(), "r");
    if (f) {
        fclose(f);
        LOGI("Found config.json, using it as config path: %s", configPath.c_str());
        pathStr = configPath;
    } else {
        LOGI("config.json not found, using directory path: %s", pathStr.c_str());
    }
    g_model_config_path_for_log = pathStr;

    try {
        if (g_llm != nullptr) {
            LOGI("LLM already initialized, resetting...");
            g_llm.reset();
        }
        
        // 创建 LLM 实例
        LOGI("Creating LLM instance from: %s", pathStr.c_str());
        g_llm.reset(MNN::Transformer::Llm::createLLM(pathStr.c_str()));
        if (g_llm == nullptr) {
            LOGE("Failed to create LLM instance");
            env->ReleaseStringUTFChars(modelPath, path);
            return;
        }

        const std::string cfg = "{"
            "\"max_input_tokens\":" + std::to_string(kMaxInputTokens) + ","
            "\"max_new_tokens\":" + std::to_string(kMaxNewTokens) +
            "}";
        bool setCfgOk = g_llm->set_config(cfg);
        LOGI("set_config(max_input_tokens=%d, max_new_tokens=%d)=%s",
             kMaxInputTokens,
             kMaxNewTokens,
             setCfgOk ? "true" : "false");
        
        // 加载模型
        LOGI("Loading LLM model...");
        bool loadResult = g_llm->load();
        if (!loadResult) {
            LOGE("Failed to load LLM model");
            g_llm.reset();
            env->ReleaseStringUTFChars(modelPath, path);
            return;
        }
        
        g_initialized = true;
        LOGI("LLM initialized and loaded successfully");
        
    } catch (const std::exception& e) {
        LOGE("Exception during init: %s", e.what());
        g_initialized = false;
        g_llm.reset();
    }
    
    env->ReleaseStringUTFChars(modelPath, path);
}

JNIEXPORT jbyteArray JNICALL
Java_com_airread_airread_MainActivity_nativeChat(JNIEnv *env, jobject thiz,
                                                  jstring prompt) {
    const char *promptStr = env->GetStringUTFChars(prompt, nullptr);
    // LOGI("nativeChat called with prompt: %s", promptStr); // Avoid logging full prompt
    
    std::string response;
    std::ostringstream oss;
    std::string userContent = promptStr;
    const std::string trimmed = arTrimAscii(userContent);
    LOGI("nativeChat input meta: model=%s len=%zu max_input_tokens=%d max_new_tokens=%d tail=%s",
         g_model_config_path_for_log.c_str(),
         trimmed.size(),
         kMaxInputTokens,
         kMaxNewTokens,
         arTail(trimmed, 120).c_str());
    
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        
        if (!g_initialized || g_llm == nullptr) {
            LOGE("LLM not initialized");
            env->ReleaseStringUTFChars(prompt, promptStr);
            std::string err = "[错误] LLM 未初始化";
            jbyteArray array = env->NewByteArray(err.length());
            env->SetByteArrayRegion(array, 0, err.length(), (const jbyte*)err.c_str());
            return array;
        }
        
        try {
            // 重置 KV 缓存，准备新一轮对话
            g_llm->reset();
            
            std::stringstream ss;
            MNN::Transformer::ChatMessages chat;
            chat.emplace_back(MNN::Transformer::ChatMessage(
                "system",
                "You are a helpful assistant.\nUse the language requested by the user. If unspecified, reply in the same language as the user."));
            chat.emplace_back(MNN::Transformer::ChatMessage("user", userContent));
            g_llm->response(chat, &ss, nullptr, kMaxNewTokens);
            response = ss.str();

            if (!arLooksMeaningfulUtf8(response)) {
                std::string fullPrompt = userContent;
                bool hasTemplate =
                    (fullPrompt.find("<|im_start|>") != std::string::npos) ||
                    (fullPrompt.find("<user>") != std::string::npos) ||
                    (fullPrompt.find("<chat_user>") != std::string::npos);
                if (!hasTemplate) {
                    fullPrompt = "<|im_start|>user\n" + fullPrompt + "<|im_end|>\n<|im_start|>assistant\n";
                }
                std::vector<int> input_ids = g_llm->tokenizer_encode(fullPrompt);
                if (!input_ids.empty()) {
                    std::stringstream ss2;
                    g_llm->reset();
                    g_llm->response(input_ids, &ss2, nullptr, kMaxNewTokens);
                    response = ss2.str();
                }
            }
            
            if (response.empty()) {
                LOGE("Response is empty!");
            }
            
        } catch (const std::exception& e) {
            LOGE("Exception during chat: %s", e.what());
            response = "[错误] 推理异常: " + std::string(e.what());
        }
    }
    
    env->ReleaseStringUTFChars(prompt, promptStr);
    
    LOGI("nativeChat returning response bytes of length %zu", response.length());
    const std::string outTrimmed = arTrimAscii(response);
    LOGI("nativeChat output tail: %s", arTail(outTrimmed, 160).c_str());
    jbyteArray array = env->NewByteArray(response.length());
    if (array == nullptr) {
        LOGE("Failed to create jbyteArray from response");
        return nullptr;
    }
    env->SetByteArrayRegion(array, 0, response.length(), (const jbyte*)response.c_str());
    return array;
}

// 自定义 streambuf 以捕获流式输出并发送到 JNI 回调
class ChunkStreamBuf : public std::streambuf {
public:
    std::function<void(const std::string&)> onChunk;
    ChunkStreamBuf(std::function<void(const std::string&)> cb) : onChunk(cb) {}

protected:
    int_type overflow(int_type c) override {
        if (c != EOF) {
            char ch = static_cast<char>(c);
            onChunk(std::string(1, ch));
        }
        return c;
    }

    std::streamsize xsputn(const char* s, std::streamsize n) override {
        if (n > 0) {
            onChunk(std::string(s, n));
        }
        return n;
    }
};

// 流式回调接口
class StreamCallback {
public:
    JNIEnv* env;
    jobject callback;
    jmethodID onChunkMethod;
    jmethodID onDoneMethod;
    jmethodID isCancelledMethod;
    
    StreamCallback(JNIEnv* e, jobject cb) : env(e), callback(cb) {
        jclass cls = env->GetObjectClass(callback);
        onChunkMethod = env->GetMethodID(cls, "onChunk", "([B)V");
        onDoneMethod = env->GetMethodID(cls, "onDone", "()V");
        isCancelledMethod = env->GetMethodID(cls, "isCancelled", "()Z");
        env->DeleteLocalRef(cls);
    }
    
    bool isCancelled() {
        if (isCancelledMethod) {
            return env->CallBooleanMethod(callback, isCancelledMethod);
        }
        return false;
    }
    
    void onChunk(const std::string& text) {
        if (onChunkMethod && !text.empty()) {
            jbyteArray bytes = env->NewByteArray(text.size());
            env->SetByteArrayRegion(bytes, 0, text.size(), (const jbyte*)text.data());
            env->CallVoidMethod(callback, onChunkMethod, bytes);
            env->DeleteLocalRef(bytes);
        }
    }
    
    void onDone() {
        if (onDoneMethod) {
            env->CallVoidMethod(callback, onDoneMethod);
        }
    }
};

JNIEXPORT void JNICALL
Java_com_airread_airread_MainActivity_nativeChatStream(JNIEnv *env, jobject thiz,
                                                        jstring prompt,
                                                        jobject callback) {
    const char *promptStr = env->GetStringUTFChars(prompt, nullptr);
    // LOGI("nativeChatStream called with prompt: %s", promptStr); // Avoid logging full prompt
    std::string userContent = promptStr;
    const std::string trimmed = arTrimAscii(userContent);
    LOGI("nativeChatStream input meta: model=%s len=%zu max_input_tokens=%d max_new_tokens=%d tail=%s",
         g_model_config_path_for_log.c_str(),
         trimmed.size(),
         kMaxInputTokens,
         kMaxNewTokens,
         arTail(trimmed, 120).c_str());
    
    // 创建回调包装器
    StreamCallback streamCb(env, callback);
    
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        
        if (!g_initialized || g_llm == nullptr) {
            LOGE("LLM not initialized");
            env->ReleaseStringUTFChars(prompt, promptStr);
            return;
        }
        
        try {
            // 重置 KV 缓存，准备新一轮对话
            g_llm->reset();
            
            // 使用自定义 streambuf 来捕获输出并支持取消
            ChunkStreamBuf customBuf([&streamCb](const std::string& chunk) {
                if (streamCb.isCancelled()) {
                    // 抛出异常以中断生成
                    throw std::runtime_error("Generation cancelled by user");
                }
                streamCb.onChunk(chunk);
            });
            std::ostream customOs(&customBuf);
            
            try {
                MNN::Transformer::ChatMessages chat;
                chat.emplace_back(MNN::Transformer::ChatMessage(
                    "system",
                    "You are a helpful assistant.\nUse the language requested by the user. If unspecified, reply in the same language as the user."));
                chat.emplace_back(MNN::Transformer::ChatMessage("user", userContent));
                g_llm->response(chat, &customOs, nullptr, kMaxNewTokens);
            } catch (const std::runtime_error& e) {
                if (std::string(e.what()) == "Generation cancelled by user") {
                    LOGI("Generation cancelled by user (caught in response wrapper)");
                } else {
                    throw;
                }
            }
            
        } catch (const std::exception& e) {
            LOGE("Exception during stream chat: %s", e.what());
        }
    }
    
    streamCb.onDone();
    env->ReleaseStringUTFChars(prompt, promptStr);
}

JNIEXPORT jstring JNICALL
Java_com_airread_airread_MainActivity_nativeDumpConfig(JNIEnv *env, jobject thiz) {
    LOGI("nativeDumpConfig called");

    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_initialized || g_llm == nullptr) {
        std::string config = "{";
        config += "\"backend\":\"MNN\",";
        config += "\"available\":" + std::string(g_initialized ? "true" : "false") + ",";
        config += "\"initialized\":" + std::string(g_initialized ? "true" : "false");
        config += "}";
        return env->NewStringUTF(config.c_str());
    }

    std::string dumped;
    try {
        dumped = g_llm->dump_config();
    } catch (...) {
        dumped = "{}";
    }

    const size_t kMaxReturn = 6000;
    if (dumped.size() > kMaxReturn) dumped = dumped.substr(0, kMaxReturn);
    return env->NewStringUTF(dumped.c_str());
}

} // extern "C"
