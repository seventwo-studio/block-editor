# Native system input acceptance

Component calls such as UIKit/AppKit marked-text methods, Compose semantics typing,
and an intercepted Android input session do not replace installed input-method
acceptance. Keep each platform family, minimum/current runtime, input method and
accessibility workflow separate. Compile checks and AX visibility alone do not
close an interaction row.

## Android installed-keyboard runner

`scripts/test-android-system-ime.py` runs an opt-in `SystemImeTest` against fresh,
ephemeral replicas. The test uses the installed Japanese Gboard QWERTY layout, not a replacement keyboard
or a test-created `InputConnection`. Actual keyboard touches enter composing Kana `か`. While that composition is visible, the persisted engine text must remain unchanged
and an incoming remote change must have no received receipt. Enter commits through the installed keyboard; the test checks both authors' text,
a mapped caret, original italic marks and an unchanged atomic mention, convergence
and touches the actual Undo/Redo controls while preserving the remote prefix.
The runner then saves into an isolated file, force-stops the test host and restores
that history in another process. Distinct process IDs and Undo/Redo after reopening
are asserted. This proves the small library host's save/restore contract; it does
not accept a production application's recovery workflow.

The explicit `gboard-japanese-qwerty-1080x2400` layout is limited to the retained API 35 ARM64
emulator configuration. Other sizes, keyboards and layouts require their own
reviewed key coordinates and interaction evidence. The runner refuses to switch
keyboards, does not clear existing app drafts, and keeps screenshots, instrument
output, runtime/keyboard/target metadata, production source hash and APK/JNI hashes.
A failed run is a failed acceptance result even when `am instrument` exits zero.
Normal test suites skip this opt-in case; they therefore cannot claim installed
keyboard coverage.

Build the current JNI engine first. In the isolated test emulator, select the
already installed Gboard Japanese QWERTY option; stop if setup requires a download.
Retain the original English-only setup and restore it after testing. The runner
checks the active Japanese subtype and does not change preferences. Run with the
existing SDK and toolchain:

```sh
ANDROID_HOME=/path/to/existing/sdk \
ANDROID_SERIAL=emulator-5556 \
JAVA_HOME=/path/to/java17 \
GRADLE_BIN=/path/to/gradle \
python3 scripts/test-android-system-ime.py \
  --keyboard-layout gboard-japanese-qwerty-1080x2400 \
  --output /absolute/path/to/evidence
```

Production source hashes identify source content; they alone do not prove that
an arbitrarily supplied native binary was built from that source. Preserve native
build provenance and establish equality before reusing a JNI artifact.

The separate opt-in `nativePlainPasteAndHostOwnedImage` test puts plain Unicode
text and an untrusted HTML alternative on the native clipboard, opens the real
Paste menu by long touch, and taps its observed screen bounds. It checks that only
the plain text enters the empty block, unrelated rich content and an atomic
reference stay identical, and Undo restores the original document. A host-provided
local bitmap renders an opaque `asset:host-owned` identifier and receives an actual
touch. This accepts native plain clipboard paste and that local renderer boundary;
it does not accept structured paste, an asset picker or network asset transport.
Run this method separately with instrumentation argument `nativeClipboard=true`;
or run `scripts/test-android-system-ime.py --phase clipboard --output /new/evidence`
with the same SDK, serial and Gradle environment. This phase uses the existing
Gboard setup and does not require the Japanese layout. The default keyboard phase
executes composition and process reopen.

This narrow runner does not accept API 26 input, physical-device behavior,
TalkBack, cross-parent focus, full rich authoring,
structured paste, asset acquisition or the complete editor matrix. ST-103 retains those
criteria; ST-45/ST-46 and ST-41 stay open until their own acceptance is complete.

## API 26 built-in IME candidate

`scripts/run-android-ci.py 26 x86_64 --system-ime` reuses the pinned CI job's
already booted emulator and installed test APK. It does not install a keyboard,
change a subtype, create another input connection or inject composing text.
`BuiltinImeTest` locates the installed AOSP LatinIME letter/Space keys in the
input-method accessibility window and injects actual touchscreen events at their
observed bounds. A vanilla Compose field must first demonstrate an active
composing range while entering `cat`. Direct committed letters fail this test.
The editor then holds a remote prefix until actual Space commits, preserves a
separate Unicode/italic/reference block, maps the caret, converges replicas and
undoes only the local author's input. The runner force-stops the host, restores
the saved history in another process, and runs the native plain paste/local bitmap
method separately. Keyboard key bounds, screenshots, input-method state, proof,
source/test hashes and packaged JNI/APK hashes are retained in
`test-results/system-input`; supplied and installed APK bytes must match.

This candidate has compiled locally with existing API35 toolchains. API26 is
absent locally, so built-in keyboard behavior and the complete opt-in CI path
remain unverified until the exact delivered source runs in the pinned API26 job.
An unknown keyboard tree, missing composition or a skipped method fails the
acceptance row. Accessibility bounds here locate touches; they do not establish
TalkBack focus, spoken feedback or activation acceptance.

Clipboard cleanup uses `clearPrimaryClip` only on API28 and later. On API26/27,
an originally absent clip becomes an empty plain-text clip because those APIs
cannot clear it; an existing clip is restored exactly. Only the disposable test
host's clipboard fixture is changed.

## API 35 observation on 1 October 2026

The system keyboard test passes on API 35 ARM64 with target SDK 35 and Gboard
14.2.09.629370537-preload-arm64-v8a. Production sources are unchanged from
`e787146c432e649e71a1a6423fe4a24c55e21f5c`; the test-only candidate is local and
uncommitted. The keyboard/control run finishes in 4.901 seconds; a separate
reopen run finishes in 2.037 seconds with process IDs `20532` and `20713`. Native IME state
records composing range `0..1`; received receipts remain empty until Enter. After
commit, both replicas match and the caret maps to offset 2. Undo leaves exactly
the remote-only document, including the original Unicode, italic mark and atomic
mention. Redo restores the converged document before saving; Undo/Redo after a
real force-stop and process restart preserve the same history. Retained screenshots
show composing Kana, the remote text after undo and the reopened document.

The subsequent native paste/local-image method passes in 4.022 seconds. Its source
adds that method after the keyboard/reopen run; all final test source compiles,
but keyboard/reopen has not been rerun against the last added test method. Preserve
the separate source/APK hashes in each evidence record when reviewing this candidate.

A vanilla Compose text-field control first established keyboard behavior. English
QWERTY emits direct committed letters even with correction enabled; this does not
prove composition. Japanese QWERTY emits `ｋ` then `か`, both with a live `0..1`
composing range. No editor adapter change was needed. The temporary Japanese
layout was removed; the original English (US) QWERTY subtype and Gboard were
verified afterward.

## Available Apple runtimes

The 1 October 2026 inventory has iOS/iPadOS 27, tvOS 27 and watchOS 27 simulator
runtimes. Apple OS 26 and a visionOS runtime are not installed. Existing compilation
and prior current-runtime app/input evidence must remain bounded to those exact
runtimes; it does not establish the minimum-runtime or visionOS interaction rows.
Do not silently download SDKs or treat missing runtimes as successful acceptance.
