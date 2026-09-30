#!/bin/sh
set -eu
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to Android NDK r30}"
SWIFT_BIN=${SWIFT_BIN:-swift}
NDK_HOST=${NDK_HOST:-darwin-x86_64}
for ABI in arm64-v8a x86_64; do
  case "$ABI" in
    arm64-v8a) TRIPLE=aarch64-unknown-linux-android26; CLANG=aarch64-linux-android26-clang; NDK_TRIPLE=aarch64-linux-android ;;
    x86_64) TRIPLE=x86_64-unknown-linux-android26; CLANG=x86_64-linux-android26-clang; NDK_TRIPLE=x86_64-linux-android ;;
  esac
  "$SWIFT_BIN" build --swift-sdk swift-6.4.0-RELEASE_android --triple "$TRIPLE" \
    --scratch-path ".build/android-$ABI" --product BlockEditorBridge -c release --static-swift-stdlib
  BIN_DIR=$("$SWIFT_BIN" build --swift-sdk swift-6.4.0-RELEASE_android --triple "$TRIPLE" \
    --scratch-path ".build/android-$ABI" -c release --show-bin-path)
  OUTPUT="android/editor/src/main/jniLibs/$ABI"
  mkdir -p "$OUTPUT"
  cp "$BIN_DIR/libBlockEditorBridge.so" "$OUTPUT/"
  # The statically linked Swift runtime still depends on the NDK C++ runtime.
  cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST/sysroot/usr/lib/$NDK_TRIPLE/libc++_shared.so" "$OUTPUT/"
  "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST/bin/$CLANG" \
    -shared -fPIC -Wl,-z,max-page-size=16384 android/editor/src/main/cpp/bridge.c \
    -L"$OUTPUT" -lBlockEditorBridge -o "$OUTPUT/libBlockEditorJNI.so"
done
