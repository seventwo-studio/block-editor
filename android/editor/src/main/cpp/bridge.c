#include <jni.h>
#include <stdint.h>
#include <string.h>

extern uint8_t *block_editor_call(const uint8_t *input, int32_t length);
extern void block_editor_free(uint8_t *pointer);

JNIEXPORT jbyteArray JNICALL
Java_studio_seventwo_blockeditor_NativeEngine_callNative(JNIEnv *env, jobject self, jbyteArray input) {
    (void)self;
    jsize size = (*env)->GetArrayLength(env, input);
    if (size > 64000000) return NULL;
    jbyte *bytes = (*env)->GetByteArrayElements(env, input, NULL);
    if (!bytes) return NULL;
    uint8_t *output = block_editor_call((uint8_t *)bytes, size);
    (*env)->ReleaseByteArrayElements(env, input, bytes, JNI_ABORT);
    if (!output) return NULL;
    size_t length = strlen((const char *)output);
    jbyteArray result = (*env)->NewByteArray(env, (jsize)length);
    if (result) (*env)->SetByteArrayRegion(env, result, 0, (jsize)length, (const jbyte *)output);
    block_editor_free(output);
    return result;
}
