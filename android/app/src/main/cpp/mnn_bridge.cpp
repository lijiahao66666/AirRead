#include <jni.h>
#include <string>

extern "C" JNIEXPORT jstring JNICALL
Java_com_airread_airread_MainActivity_stringFromJNI(
        JNIEnv* env,
        jobject /* this */) {
    std::string hello = "Hello from C++ (Mock)";
    return env->NewStringUTF(hello.c_str());
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_airread_airread_MainActivity_nativeIsAvailable(JNIEnv* env, jobject thiz) {
    return JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_airread_airread_MainActivity_nativeInit(JNIEnv* env, jobject thiz, jstring modelPath) {}

extern "C" JNIEXPORT void JNICALL
Java_com_airread_airread_MainActivity_nativeDispose(JNIEnv* env, jobject thiz) {}

extern "C" JNIEXPORT jstring JNICALL
Java_com_airread_airread_MainActivity_nativeDumpConfig(JNIEnv* env, jobject thiz) {
    return env->NewStringUTF("{}");
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_airread_airread_MainActivity_nativeChat(JNIEnv* env, jobject thiz, jstring prompt) {
    return nullptr;
}

extern "C" JNIEXPORT void JNICALL
Java_com_airread_airread_MainActivity_nativeChatStream(JNIEnv* env, jobject thiz, jstring prompt, jobject callback) {}
