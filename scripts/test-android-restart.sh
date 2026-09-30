#!/bin/sh
set -eu
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK}"
: "${DEMO_TOKEN:?Set DEMO_TOKEN to the local relay token}"
ADB="$ANDROID_HOME/platform-tools/adb"
DEMO_URL=${DEMO_URL:-http://127.0.0.1:4319}
ANDROID_RELAY_URL=${ANDROID_RELAY_URL:-http://10.0.2.2:4319}
ANDROID_DRAFT_RUN="android-restart-$(date +%s)-$$"
"$ADB" install -r android/demo/build/outputs/apk/debug/demo-debug.apk
"$ADB" install -r android/demo/build/outputs/apk/androidTest/debug/demo-debug-androidTest.apk
run_phase() {
  result=$("$ADB" shell am instrument -w -r \
    -e class 'studio.seventwo.blockeditor.demo.DraftTest#processRestartPhase' \
    -e draftPhase "$1" -e draftRun "$ANDROID_DRAFT_RUN" \
    -e relayUrl "$ANDROID_RELAY_URL" -e relayToken "$DEMO_TOKEN" \
    studio.seventwo.blockeditor.demo.test/androidx.test.runner.AndroidJUnitRunner)
  printf '%s\n' "$result"
  case "$result" in *'OK (1 test)'*) ;; *) exit 1 ;; esac
}
run_phase save
"$ADB" shell am force-stop studio.seventwo.blockeditor.demo
DEMO_ENDPOINT="$DEMO_URL/rooms/$ANDROID_DRAFT_RUN" DEMO_TEXT=' remote process edit 世界' .build/debug/relay-client
run_phase restore
