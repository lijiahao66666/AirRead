#include <jni.h>
#include <string>
#include <android/log.h>
#include <memory>
#include <sstream>
#include <streambuf>
#include <thread>
#include <mutex>

#ifdef ENABLE_MNN
#include <MNN/llm/llm.hpp>
#endif

#define TAG "MNN_LLM"

#ifdef ENABLE_MNN
static std::unique_ptr<MNN::Transformer::Llm> g_llm;
static std::string g_model_path;
static std::mutex g_llm_mutex;

static int defaultThreadNum() {
    unsigned int hc = std::thread::hardware_concurrency();
    int t = hc > 0 ? static_cast<int>(hc) : 4;
    if (t > 6) t = 6;
    if (t < 2) t = 2;
    return t;
}

static void ensureThreadConfig(MNN::Transformer::Llm* llm) {
    if (llm == nullptr) return;
    std::string cfg;
    try {
        cfg = llm->dump_config();
    } catch (...) {
        cfg.clear();
    }
    if (!cfg.empty()) {
        if (cfg.find("\"thread_num\"") != std::string::npos) return;
        if (cfg.find("\"numThread\"") != std::string::npos) return;
        if (cfg.find("\"num_thread\"") != std::string::npos) return;
    }
    const int t = defaultThreadNum();
    std::ostringstream os;
    os << "{\"thread_num\":" << t << "}";
    const auto ok = llm->set_config(os.str());
    if (!ok) {
        __android_log_print(ANDROID_LOG_WARN, TAG, "set_config(thread_num=%d) returned false", t);
    } else {
        __android_log_print(ANDROID_LOG_INFO, TAG, "Applied thread_num=%d", t);
    }
}

static jmethodID getMethodIdSafe(JNIEnv* env, jclass cls, const char* name, const char* sig) {
    jmethodID mid = env->GetMethodID(cls, name, sig);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        __android_log_print(ANDROID_LOG_ERROR, TAG, "Missing callback method: %s %s", name, sig);
        return nullptr;
    }
    return mid;
}

static std::vector<int> trimPromptToTokens(MNN::Transformer::Llm* llm, const std::string& prompt, int max_input_tokens) {
    if (llm == nullptr) return {};
    const auto ids = llm->tokenizer_encode(prompt);
    if (max_input_tokens <= 0) return ids;
    if (static_cast<int>(ids.size()) <= max_input_tokens) return ids;

    int head = max_input_tokens / 4;
    if (head > 128) head = 128;
    if (head < 0) head = 0;
    if (head > max_input_tokens) head = max_input_tokens;
    int tail = max_input_tokens - head;

    std::vector<int> out;
    out.reserve(static_cast<size_t>(max_input_tokens));

    if (head > 0) {
        out.insert(out.end(), ids.begin(), ids.begin() + head);
    }

    if (tail > 0) {
        const auto sep = llm->tokenizer_encode("\n");
        if (!sep.empty()) {
            out.insert(out.end(), sep.begin(), sep.end());
        }
        const size_t total = ids.size();
        const size_t tailStart = total > static_cast<size_t>(tail) ? (total - static_cast<size_t>(tail)) : 0;
        out.insert(out.end(), ids.begin() + tailStart, ids.end());
    }

    if (static_cast<int>(out.size()) > max_input_tokens) {
        out.erase(out.begin() + max_input_tokens, out.end());
    }
    return out;
}

static void applyRuntimeConfig(
    MNN::Transformer::Llm* llm,
    double temperature,
    double top_p,
    int top_k,
    double min_p,
    double presence_penalty,
    double repetition_penalty,
    int enable_thinking
) {
    if (llm == nullptr) return;

    std::ostringstream os;
    bool hasAny = false;
    os << "{";

    auto addCommaIfNeeded = [&]() {
        if (hasAny) os << ",";
        hasAny = true;
    };

    if (temperature >= 0.0) {
        addCommaIfNeeded();
        os << "\"temperature\":" << temperature;
    }
    if (top_p >= 0.0) {
        addCommaIfNeeded();
        os << "\"top_p\":" << top_p;
    }
    if (top_k >= 0) {
        addCommaIfNeeded();
        os << "\"top_k\":" << top_k;
    }
    if (min_p >= 0.0) {
        addCommaIfNeeded();
        os << "\"min_p\":" << min_p;
    }
    if (presence_penalty >= 0.0) {
        addCommaIfNeeded();
        os << "\"presence_penalty\":" << presence_penalty;
    }
    if (repetition_penalty >= 0.0) {
        addCommaIfNeeded();
        os << "\"repetition_penalty\":" << repetition_penalty;
    }
    if (enable_thinking == 0 || enable_thinking == 1) {
        addCommaIfNeeded();
        os << "\"enable_thinking\":" << (enable_thinking == 1 ? "true" : "false");
    }

    os << "}";
    if (!hasAny) return;

    const auto ok = llm->set_config(os.str());
    if (!ok) {
        __android_log_print(ANDROID_LOG_WARN, TAG, "set_config returned false");
    }
}

static std::string toChatPrompt(MNN::Transformer::Llm* llm, const std::string& user_content) {
    if (llm == nullptr) return user_content;
    std::string out;
    try {
        out = llm->apply_chat_template(user_content);
    } catch (...) {
        out.clear();
    }
    if (out.empty()) return user_content;
    return out;
}

struct StreamCancelledException {};
#endif

extern "C" JNIEXPORT jboolean JNICALL
Java_com_airread_airread_MainActivity_nativeIsAvailable(JNIEnv* env, jobject thiz) {
#ifdef ENABLE_MNN
    return JNI_TRUE;
#else
    return JNI_FALSE;
#endif
}

extern "C" JNIEXPORT void JNICALL
Java_com_airread_airread_MainActivity_nativeInit(JNIEnv* env, jobject thiz, jstring model_path) {
    const char* path = env->GetStringUTFChars(model_path, 0);
    
    __android_log_print(ANDROID_LOG_INFO, TAG, "Initializing model from: %s", path);

#ifdef ENABLE_MNN
    std::lock_guard<std::mutex> lock(g_llm_mutex);
    if (!g_model_path.empty() && g_model_path == path && g_llm) {
        __android_log_print(ANDROID_LOG_INFO, TAG, "Model already initialized");
        env->ReleaseStringUTFChars(model_path, path);
        return;
    }

    g_model_path = path;
    g_llm.reset(MNN::Transformer::Llm::createLLM(g_model_path));
    if (g_llm) {
        const auto ok = g_llm->load();
        if (ok) {
            ensureThreadConfig(g_llm.get());
            __android_log_print(ANDROID_LOG_INFO, TAG, "Model loaded successfully");
        } else {
            __android_log_print(ANDROID_LOG_ERROR, TAG, "Model load failed");
        }
    } else {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "Failed to create model instance");
    }
#else
    __android_log_print(ANDROID_LOG_WARN, TAG, "MNN is disabled. Please configure MNN libraries to enable local inference.");
#endif

    env->ReleaseStringUTFChars(model_path, path);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_airread_airread_MainActivity_nativeDumpConfig(JNIEnv* env, jobject thiz) {
#ifdef ENABLE_MNN
    std::lock_guard<std::mutex> lock(g_llm_mutex);
    if (!g_llm) {
        return env->NewStringUTF("");
    }
    const auto cfg = g_llm->dump_config();
    return env->NewStringUTF(cfg.c_str());
#else
    return env->NewStringUTF("");
#endif
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_airread_airread_MainActivity_nativeChat(
    JNIEnv* env,
    jobject thiz,
    jstring prompt,
    jint max_new_tokens,
    jint max_input_tokens,
    jdouble temperature,
    jdouble top_p,
    jint top_k,
    jdouble min_p,
    jdouble presence_penalty,
    jdouble repetition_penalty,
    jint enable_thinking
) {
    const char* input_str = env->GetStringUTFChars(prompt, 0);
    std::string response;

#ifdef ENABLE_MNN
    std::lock_guard<std::mutex> lock(g_llm_mutex);
    if (!g_llm) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "LLM not initialized");
        env->ReleaseStringUTFChars(prompt, input_str);
        return env->NewStringUTF("Error: Model not initialized");
    }
    
    g_llm->reset();
    applyRuntimeConfig(g_llm.get(), temperature, top_p, static_cast<int>(top_k), min_p, presence_penalty, repetition_penalty, static_cast<int>(enable_thinking));
    const std::string chatPrompt = toChatPrompt(g_llm.get(), std::string(input_str));
    std::stringstream ss;
    const int maxTokens = max_new_tokens > 0 ? static_cast<int>(max_new_tokens) : 256;
    const char* endWith = "<|im_end|>";
    if (max_input_tokens > 0) {
        const auto ids = trimPromptToTokens(g_llm.get(), chatPrompt, static_cast<int>(max_input_tokens));
        g_llm->response(ids, &ss, endWith, maxTokens);
    } else {
        g_llm->response(chatPrompt, &ss, endWith, maxTokens);
    }
    response = ss.str();
#else
    response = "【系统提示】本地推理引擎尚未集成。请按照项目文档下载 MNN 库文件并配置 android/app/src/main/cpp/mnn_bridge.cpp 以启用本地模型功能。";
#endif

    env->ReleaseStringUTFChars(prompt, input_str);
    return env->NewStringUTF(response.c_str());
}

#ifdef ENABLE_MNN
class CallbackStreamBuf : public std::streambuf {
public:
    CallbackStreamBuf(JNIEnv* env, jobject callback)
        : env_(env), callback_(callback) {
        jclass cls = env_->GetObjectClass(callback_);
        onChunk_ = getMethodIdSafe(env_, cls, "onChunk", "(Ljava/lang/String;)V");
        isCancelled_ = getMethodIdSafe(env_, cls, "isCancelled", "()Z");
        env_->DeleteLocalRef(cls);
    }

    ~CallbackStreamBuf() override {
        try {
            flushPending(true, false);
        } catch (...) {
        }
    }

protected:
    int overflow(int ch) override {
        if (ch == EOF) {
            flushPending(true, true);
            return 0;
        }
        throwIfCancelled();
        pending_.push_back(static_cast<char>(ch));
        flushPending(false, true);
        return ch;
    }

    std::streamsize xsputn(const char* s, std::streamsize n) override {
        if (n <= 0) return 0;
        throwIfCancelled();
        pending_.append(s, static_cast<size_t>(n));
        flushPending(false, true);
        return n;
    }

    int sync() override {
        flushPending(true, true);
        return 0;
    }

private:
    static size_t validUtf8Prefix(const std::string& s) {
        size_t i = 0;
        const size_t n = s.size();
        while (i < n) {
            unsigned char c = static_cast<unsigned char>(s[i]);
            size_t len = 0;
            if (c <= 0x7F) {
                len = 1;
            } else if ((c & 0xE0) == 0xC0) {
                len = 2;
            } else if ((c & 0xF0) == 0xE0) {
                len = 3;
            } else if ((c & 0xF8) == 0xF0) {
                len = 4;
            } else {
                break;
            }
            if (i + len > n) break;
            for (size_t j = 1; j < len; j++) {
                unsigned char cc = static_cast<unsigned char>(s[i + j]);
                if ((cc & 0xC0) != 0x80) return i;
            }
            i += len;
        }
        return i;
    }

    bool isCancelledNow() {
        if (isCancelled_ == nullptr) return false;
        const auto cancelled = env_->CallBooleanMethod(callback_, isCancelled_);
        if (env_->ExceptionCheck()) {
            env_->ExceptionClear();
        }
        return cancelled == JNI_TRUE;
    }

    void throwIfCancelled() {
        if (isCancelledNow()) {
            pending_.clear();
            throw StreamCancelledException();
        }
    }

    void flushPending(bool force, bool allowThrow) {
        if (pending_.empty()) return;
        if (!force && pending_.size() < 48) return;
        if (isCancelledNow()) {
            pending_.clear();
            if (allowThrow) throw StreamCancelledException();
            return;
        }
        if (onChunk_ == nullptr) {
            pending_.clear();
            return;
        }
        const auto prefixLen = validUtf8Prefix(pending_);
        if (prefixLen == 0) {
            if (force) pending_.clear();
            return;
        }
        const std::string out = pending_.substr(0, prefixLen);
        pending_.erase(0, prefixLen);
        jstring chunk = env_->NewStringUTF(out.c_str());
        env_->CallVoidMethod(callback_, onChunk_, chunk);
        env_->DeleteLocalRef(chunk);
        if (env_->ExceptionCheck()) {
            env_->ExceptionClear();
        }
    }

private:
    JNIEnv* env_;
    jobject callback_;
    jmethodID onChunk_ = nullptr;
    jmethodID isCancelled_ = nullptr;
    std::string pending_;
};
#endif

extern "C" JNIEXPORT void JNICALL
Java_com_airread_airread_MainActivity_nativeChatStream(
    JNIEnv* env,
    jobject thiz,
    jstring prompt,
    jint max_new_tokens,
    jint max_input_tokens,
    jdouble temperature,
    jdouble top_p,
    jint top_k,
    jdouble min_p,
    jdouble presence_penalty,
    jdouble repetition_penalty,
    jint enable_thinking,
    jobject callback
) {
    const char* input_str = env->GetStringUTFChars(prompt, 0);

#ifdef ENABLE_MNN
    std::lock_guard<std::mutex> lock(g_llm_mutex);
    if (!g_llm) {
        env->ReleaseStringUTFChars(prompt, input_str);
        return;
    }

    g_llm->reset();
    applyRuntimeConfig(g_llm.get(), temperature, top_p, static_cast<int>(top_k), min_p, presence_penalty, repetition_penalty, static_cast<int>(enable_thinking));
    const std::string chatPrompt = toChatPrompt(g_llm.get(), std::string(input_str));
    const int maxTokens = max_new_tokens > 0 ? static_cast<int>(max_new_tokens) : 256;
    const char* endWith = "<|im_end|>";
    {
        CallbackStreamBuf buf(env, callback);
        std::ostream os(&buf);
        try {
            if (max_input_tokens > 0) {
                const auto ids = trimPromptToTokens(g_llm.get(), chatPrompt, static_cast<int>(max_input_tokens));
                g_llm->response(ids, &os, endWith, maxTokens);
            } else {
                g_llm->response(chatPrompt, &os, endWith, maxTokens);
            }
            os.flush();
        } catch (const StreamCancelledException&) {
        } catch (...) {
        }
    }

    jclass cls = env->GetObjectClass(callback);
    jmethodID onDone = getMethodIdSafe(env, cls, "onDone", "()V");
    env->DeleteLocalRef(cls);
    if (onDone != nullptr) {
        env->CallVoidMethod(callback, onDone);
        if (env->ExceptionCheck()) {
            env->ExceptionClear();
        }
    }
#else
    (void)callback;
#endif

    env->ReleaseStringUTFChars(prompt, input_str);
}
