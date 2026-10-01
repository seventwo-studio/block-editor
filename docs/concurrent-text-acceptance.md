# Concurrent text, formatting and author undo acceptance

ST-41 preserves the completed shared Unicode/formatting convergence and generated
offline multi-replica criteria. Its remaining IME/selection criterion depends on
[Apple ST-102](https://linear.app/seventwo/issue/ST-102),
[Android ST-103](https://linear.app/seventwo/issue/ST-103) and
[browser ST-104](https://linear.app/seventwo/issue/ST-104).
Passing engine fixtures or merging adapter code does not complete those input rows.

## Independent engine fixtures

`IndependentTextAcceptanceTests.swift` uses the public `EditorSession` API with
literal document/text expectations. It covers collaboration versions 1 and 2:

- All 24 orders of four concurrent text/format edits, with every packet duplicated,
  preserve an atomic mention, consumer extension field and both authors' marks.
- Same-author save/restore between successive undo/redo actions preserves the other
  author's combining Unicode insertion and formatting. Stable reference positions
  map through deletion and its undo; another restored actor has no local history.
- Undoing one author's overlapping deletion cannot resurrect text still deleted
  by another author. Restored undo/redo histories converge with exact receipts.

These are host engine tests. They do not exercise an input method, native focus,
cross-parent movement or the React/WASM/JNI runtimes. Split/merge and new structural
commands require independent fixtures under their owning issues.

The candidate starts at default `e7d616a0262eac4c368fdcf83f18890b5a83e5ac`.
All four parameterized cases passed in ST-42's frozen host checkpoint using Swift
6.4, arm64/macOS 27 SDK and the package's OS 26 minimum. The two test functions
passed in 0.011 and 0.035 seconds. The frozen test file SHA-256 is
`63d324b9b56d4ac8ed85ab0467308bbc38033432c4a790731628c7a7522be2cd`.
Retained output `/tmp/st42-writing-checkpoint.log` has SHA-256
`d548e8c92a5f0c382e38ba4773f782b89bb3e852bf47b4a8b6a144b7b6fba5e3`.

Execution used ST-42's `shared-writing` source at `e787146` with uncommitted v3
additions and its exclusive `nested-structure/.build` cache, not this candidate's
unchanged default tree. All 19 functions in the scoped writing/independent run
passed; this is not a whole-package run. Independently verified all six source/test
hashes in `/tmp/st42-checkpoint-provenance.json` and confirmed tracked legacy core
sources equal `e7d616a`. V3 session SHA-256 is
`7311eceb4c9d43fa963bc151c7a3d8a41c351ca7611fec3a79e28ae24d7dcc88`;
projection SHA-256 is
`3d76eda3c0408e17623725cae7a835edccd43ba174f0c46af9e1efc436029714`.
The checkpoint is local source, not a committed or delivered release artifact.

## Input evidence reviewed on 1 October 2026

| Surface | Evidence | Remaining acceptance |
| --- | --- | --- |
| Android API 35 ARM64 emulator | Actual installed Japanese Gboard QWERTY touches, composing Kana, held remote receipts, native Enter commit, mapped caret, Unicode/italic/mention preservation, convergence and author Undo/Redo; force-stop/reopen in another process | API 26 actual input, physical ARM64 and broader focus/authoring/accessibility matrix remain open in ST-103 |
| Apple macOS/iOS/iPadOS | Prior AppKit/UIKit component marked-text and mapped selection/formatting tests, plus recorded iPhone/iPad workflows; ST-45 reports no fresh system IME run | Real system IME and full-view moved-content focus/reference checks remain open in ST-102; minimum/current runtime rows must stay separate |
| Apple visionOS/watchOS/tvOS | Prior library builds and platform draft/component checks | Per-family real input remains open; visionOS runtime and Apple OS 26 simulator runtimes are absent in the recorded inventory |
| Chromium | Prior PR #27/#28 selection and IME protocol input, remote insertion/convergence and author undo | Current migration/runtime provenance and broader ST-104 workflows remain open; protocol input does not establish installed system IME |
| WebKit | Prior PR #27/#28 selections and dispatched composition-event checks | System IME remains unverified; file-picker/reopen needs its own evidence |
| Firefox | No accepted current input evidence supplied by ST-47 | ST-104 input/selection/composition and offline author history remain open |

### Android provenance and limits

Reviewed ST-103's live comments and retained `environment.json`, `proof.json` and
instrumentation results. The installed keyboard is Gboard
`14.2.09.629370537-preload-arm64-v8a`; device is `emulator-5556`, API 35 ARM64,
1080×2400, app/test target SDK 35. A live composing range `0..1` leaves receipts
empty and persisted text unchanged. Enter produces `Rか…`, maps the caret to 2,
and retains the original Unicode, italic mark and unchanged mention. Undo yields
the remote-only document. No TalkBack service was active.

The test-only candidate is local and uncommitted at base
`e787146c432e649e71a1a6423fe4a24c55e21f5c`; a direct Git comparison confirms
`Sources` and `android/editor/src/main` equal default
`e7d616a0262eac4c368fdcf83f18890b5a83e5ac`. This source equality does not alone
establish JNI build provenance.

Retained runs must remain distinct:

- `/tmp/editor-system-ime-japanese-final`: keyboard/commit/undo, APK SHA-256
  `a2b886ccfa52dbd349d6a5475e4c8879a5d3bbd1d826d68349f5c998c5364da1`.
- `/tmp/editor-native-reopen-20261001-pass`: keyboard/control run 4.901 seconds,
  reopen 2.037 seconds, distinct process IDs 20532 and 20713, APK SHA-256
  `425aa5a10edafc467dbf79711dd24dd4e0d2d64322acedef8aca27f0c4f61c1d`.
  Test source SHA-256:
  `1ca94499a346308f42e0513046784f857475603fc87c52a65c136becb1b6b968`.
- `/tmp/editor-native-paste-20261001-pass`: separate plain native paste and host
  bitmap touch run, 4.022 seconds, APK SHA-256
  `0de0070a38f6af55ff6fd75fb87a7ed1a753abee18cf56252ec826dba3a6cc0c`.
  Test source SHA-256:
  `5d40b8a5b2209046ebb4d5d4fc9bda05bc94d12059423000e80d18c1bb74db74`.
  Keyboard/reopen was not rerun after adding this method. Plain paste and local
  rendering do not accept structured paste, asset acquisition or production app
  recovery.

Durable source/evidence handoff is tracked by ST-103. ST-41 stays In Progress with
its existing native blocking relations until the required platform evidence is
accepted. No new structural-command completion is attributed to ST-41.

## V3 input contract review

Read-only review of ST-42's unfinished `WritingSession` identified two requirements
before native adoption. The owner accepted them for its implementation:

- Bound remote composition holds and capture selections before materialization,
  matching the existing adapter contract. A command's `isComposing` guard alone
  does not defer incoming remote changes. Pending batches must stay outside
  accepted receipts/save, and disposal must release the hold safely.
- Preserve displayed positions inside atomic reference labels, as v1/v2 supports.
  Edits still reject partial-reference ranges. Returning only atom-boundary
  positions can reject selections produced by a native or browser renderer.

Both contracts are implemented in the frozen checkpoint and its focused engine
tests pass. This does not establish native input acceptance. ST-42 accepted an
additional queue-loss finding: a callback can create a new receive hold and queue
another packet while `retryDeferredChanges` replays older packets, after which
assigning only failed packets discards newly queued input. The owner preserves
callback-added packets, reserves count/byte capacity during the drain and rejects
nested drains. Its public reproduction fixture awaits the next reserved host run;
this later fix is outside the passing frozen checkpoint above.

The authoritative source is ST-42's `shared-writing` checkout; ST-41 makes no
production core changes. V3 still requires independent shared-runtime and platform
acceptance under the owning command/input issues.
