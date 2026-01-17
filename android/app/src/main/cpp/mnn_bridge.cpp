#include <jni.h>
#include <string>
#include <android/log.h>
#include <memory>
#include <sstream>
#include <streambuf>
#include <mutex>

#ifdef ENABLE_MNN
#include <MNN/llm/llm.hpp>
#endif

#define TAG "MNN_LLM"

#ifdef ENABLE_MNN
static std::unique_ptr<MNN::Transformer::Llm> g_llm;
static std::string g_model_path;
static std::mutex g_llm_mutex;

static jmethodID getMethodIdSafe(JNIEnv* env, jclass cls, const char* name, const char* sig) {
    jmethodID mid = env->GetMethodID(cls, name, sig);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        __android_log_print(ANDROID_LOG_ERROR, TAG, "Missing callback method: %s %s", name, sig);
        return nullptr;
    }
    return mid;
}
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
Java_com_airread_airread_MainActivity_nativeChat(JNIEnv* env, jobject thiz, jstring prompt) {
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
    std::stringstream ss;
    g_llm->response(input_str, &ss, nullptr, 256);
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
        flushPending(true);
    }

protected:
    int overflow(int ch) override {
        if (ch == EOF) {
            flushPending(true);
            return 0;
        }
        pending_.push_back(static_cast<char>(ch));
        flushPending(false);
        return ch;
    }

    std::streamsize xsputn(const char* s, std::streamsize n) override {
        if (n <= 0) return 0;
        pending_.append(s, static_cast<size_t>(n));
        flushPending(false);
        return n;
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

    void flushPending(bool force) {
        if (pending_.empty()) return;
        if (!force && pending_.size() < 48) return;
        if (isCancelled_ != nullptr) {
            const auto cancelled = env_->CallBooleanMethod(callback_, isCancelled_);
            if (env_->ExceptionCheck()) {
                env_->ExceptionClear();
            }
            if (cancelled == JNI_TRUE) {
                pending_.clear();
                return;
            }
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
Java_com_airread_airread_MainActivity_nativeChatStream(JNIEnv* env, jobject thiz, jstring prompt, jobject callback) {
    const char* input_str = env->GetStringUTFChars(prompt, 0);

#ifdef ENABLE_MNN
    std::lock_guard<std::mutex> lock(g_llm_mutex);
    if (!g_llm) {
        env->ReleaseStringUTFChars(prompt, input_str);
        return;
    }

    g_llm->reset();
    CallbackStreamBuf buf(env, callback);
    std::ostream os(&buf);
    g_llm->response(input_str, &os, nullptr, 256);
    os.flush();

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
