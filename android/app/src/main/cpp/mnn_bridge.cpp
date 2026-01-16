#include <jni.h>
#include <string>
#include <android/log.h>
#include <memory>
#include <sstream>

// IMPORTANT: To enable MNN, follow these steps:
// 1. Download MNN Android libraries (libMNN.so, libMNN_LLM.so) and put them in android/libs/mnn/libs/
// 2. Download MNN headers and put them in android/libs/mnn/include/
// 3. Uncomment the MNN related lines in android/app/src/main/cpp/CMakeLists.txt
// 4. Uncomment the #define ENABLE_MNN below
// 5. Uncomment the #include <llm/llm.hpp> below

// #define ENABLE_MNN

#ifdef ENABLE_MNN
#include <llm/llm.hpp>
#else
// Placeholder to allow compilation without MNN headers
namespace MNN {
namespace Transformer {
    class Llm {
    public:
        virtual ~Llm() {}
        // Dummy methods to match usage structure if needed, but we won't call them if disabled
    };
}
}
#endif

#define TAG "MNN_LLM"

// Global LLM instance
static std::unique_ptr<MNN::Transformer::Llm> g_llm;

extern "C" JNIEXPORT void JNICALL
Java_com_airread_airread_MainActivity_nativeInit(JNIEnv* env, jobject thiz, jstring model_path) {
    const char* path = env->GetStringUTFChars(model_path, 0);
    
    __android_log_print(ANDROID_LOG_INFO, TAG, "Initializing model from: %s", path);

#ifdef ENABLE_MNN
    // MNN LLM Configuration
    MNN::Transformer::Llm::Config config;
    config.path = path;
    config.mode = MNN::Transformer::Llm::LoadMode::DISK; 
    
    // Create LLM instance
    g_llm.reset(MNN::Transformer::Llm::createLLM(config));
    
    if (g_llm) {
        g_llm->load();
        __android_log_print(ANDROID_LOG_INFO, TAG, "Model loaded successfully");
    } else {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "Failed to load model. Ensure libMNN_LLM.so is linked.");
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
    if (!g_llm) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "LLM not initialized");
        env->ReleaseStringUTFChars(prompt, input_str);
        return env->NewStringUTF("Error: Model not initialized");
    }
    
    // Perform inference
    std::stringstream ss;
    g_llm->response(input_str, &ss, nullptr);
    response = ss.str();
#else
    response = "【系统提示】本地推理引擎尚未集成。请按照项目文档下载 MNN 库文件并配置 android/app/src/main/cpp/mnn_bridge.cpp 以启用本地模型功能。";
#endif

    env->ReleaseStringUTFChars(prompt, input_str);
    return env->NewStringUTF(response.c_str());
}
