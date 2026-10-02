# Installed TalkBack gesture acceptance

`TalkBackInputTest` and `scripts/test-android-talkback.py` provide a separate,
opt-in check of installed TalkBack navigation and author Undo. The test keeps
accessibility services active, requires swipe navigation to leave Undo and return
to it, then double-taps its observed bounds. The complete original document must
be restored, including Unicode and italic content. It does not invoke accessibility
click or focus actions.

The runner requires an existing API 35 ARM64 emulator, a 1080×2400 display and the
already installed TalkBack service. It verifies the touchscreen axis calibration,
compares supplied and installed APK bytes, enables the service temporarily, and
restores the original accessibility preferences in `finally`. An instrumentation
failure or skip fails the run. No build, APK installation or download is performed.

```sh
python3 scripts/test-android-talkback.py \
  --sdk /path/to/existing/android-sdk \
  --serial emulator-5556 \
  --apk /path/to/already-installed-test.apk \
  --output /new/empty/evidence-directory
```

The host runner sends touchscreen events through the emulator console after a
test-owned file handshake. The pinned emulator exposes `virtio_input_multi_touch_1`
with axis ranges 0–32767. Other devices, screen sizes or input layouts need separate
calibration and interaction evidence. Accessibility data locates the current focus;
the gesture and full document assertions establish this narrow interaction result.

## Recorded result

The [retained evidence](evidence/android-talkback-2026-10-01/manifest.json) records
one passing run in 9.473 seconds on 1 October 2026. Navigation visited real editor
controls and returned to Undo; double-tap restored the original document. TalkBack
and touch exploration remained active, and the original preferences were restored.

That run used V5 Android UI tree `1e81262e`, reused engine revision `e787146c` and
APK `d07bf3cb…`. It is not a new execution against this draft's default-branch base.
The repository includes small JSON proof, gesture trace and raw instrumentation
output; APKs, screenshots, toolchains and complete local archives remain local.

Spoken audio, full editor accessibility, physical devices, minimum-runtime behavior
and current-engine acceptance remain open. Normal component suites omit this opt-in
interaction and cannot claim its acceptance. ST-103 remains In Progress.
