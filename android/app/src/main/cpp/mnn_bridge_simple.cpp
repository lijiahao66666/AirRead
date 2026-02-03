#include <jni.h>
#include <string>

extern "C" JNIEXPORT jstring JNICALL
Java_com_airread_airread_MainActivity_stringFromJNI(
        JNIEnv* env,
        jobject /* this */) {
    std::string hello = "Hello from C++ (Simple Mock)";
    return env->NewStringUTF(hello.c_str());
}
