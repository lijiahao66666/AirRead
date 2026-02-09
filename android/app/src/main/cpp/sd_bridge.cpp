#include <jni.h>
#include <string>

#if defined(ENABLE_DIFFUSION) && ENABLE_DIFFUSION
#include <functional>
#include <memory>

#include <MNN/MNNForwardType.h>

namespace MNN {
namespace DIFFUSION {
enum DiffusionModelType {
  StableDiffusion = 0,
};

class Diffusion {
 public:
  static Diffusion* createDiffusion(std::string modelDir,
                                    DiffusionModelType type,
                                    MNNForwardType forwardType,
                                    int threadCount);
  std::string run(std::string prompt,
                  std::string negativePrompt,
                  int steps,
                  int seed,
                  std::function<void(int)> progressCallback);
};
}  // namespace DIFFUSION
}  // namespace MNN

static std::unique_ptr<MNN::DIFFUSION::Diffusion> g_diffusion;
static std::string g_model_dir;

static std::string JStringToString(JNIEnv* env, jstring js) {
  if (!js) return std::string();
  const char* cstr = env->GetStringUTFChars(js, nullptr);
  std::string out = cstr ? std::string(cstr) : std::string();
  if (cstr) env->ReleaseStringUTFChars(js, cstr);
  return out;
}

static jstring StringToJString(JNIEnv* env, const std::string& s) {
  return env->NewStringUTF(s.c_str());
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_airread_airread_MainActivity_nativeSdIsAvailable(JNIEnv*, jobject) {
  return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_airread_airread_MainActivity_nativeSdInit(JNIEnv* env,
                                                   jobject,
                                                   jstring modelDir) {
  g_model_dir = JStringToString(env, modelDir);
  g_diffusion.reset(MNN::DIFFUSION::Diffusion::createDiffusion(
      g_model_dir, MNN::DIFFUSION::StableDiffusion, MNN_FORWARD_CPU, 4));
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_airread_airread_MainActivity_nativeSdTxt2Img(JNIEnv* env,
                                                      jobject,
                                                      jstring prompt,
                                                      jint steps,
                                                      jint seed) {
  if (!g_diffusion) {
    return StringToJString(env, std::string());
  }
  const std::string promptStr = JStringToString(env, prompt);
  const std::string negative =
      "text, watermark, logo, blurry, deformed, extra limbs, low quality";
  const int stepsInt = static_cast<int>(steps);
  const int seedInt = static_cast<int>(seed);
  std::string outPath = g_diffusion->run(
      promptStr, negative, stepsInt, seedInt, [](int) {});
  return StringToJString(env, outPath);
}

#else

extern "C" JNIEXPORT jboolean JNICALL
Java_com_airread_airread_MainActivity_nativeSdIsAvailable(JNIEnv*, jobject) {
  return JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_airread_airread_MainActivity_nativeSdInit(JNIEnv*, jobject, jstring) {}

extern "C" JNIEXPORT jstring JNICALL
Java_com_airread_airread_MainActivity_nativeSdTxt2Img(JNIEnv* env,
                                                      jobject,
                                                      jstring,
                                                      jint,
                                                      jint) {
  return env->NewStringUTF("");
}

#endif
