# Shared runtime verification

ST-93 owns reproducible runtime CI. `.github/workflows/ci.yml` runs on pull requests
and pushes to the actual default branch, `codex/initial-extract`. The existing
TypeScript, React browser, package smoke and demo checks remain separate.

## Runtime matrix

| Job | Host and runtime | Actual execution |
| --- | --- | --- |
| Swift | `macos-26`, Xcode 26.6/macOS SDK 26.5, official Swift 6.4.0 | Native Swift core/Apple/demo tests, shared bridge transcripts and independent-process relay stress |
| Android minimum | `ubuntu-24.04`, Google APIs API 26 x86_64 revision 16 | Single-ABI x86_64 APK, Kotlin/JNI fixture transcripts and compatibility tests |
| Android reference | `ubuntu-24.04`, Google APIs API 35 x86_64 revision 9 | Single-ABI x86_64 APK, Kotlin/JNI fixture transcripts and compatibility tests |
| Android ARM64 | Same pinned API 35 image, Google's ARM translation | Single-ABI ARM64 APK; execute the ARM64 JNI and Swift libraries through Android's native bridge |
| Browser | `ubuntu-24.04`, Playwright versions from `bun.lock` | Freshly built Swift WASM, fixtures and reference input tests in Chromium, WebKit and Firefox |

ARM translation executes the packaged ARM64 code; it is not a physical ARM device,
an ARM64 system image, or a performance baseline. Android tests verify the chosen
package ABI, ELF machine, actual API and system ABI list. Missing translation
support fails the job; it cannot substitute an x86 library. Google's
[ARM emulator announcement](https://android-developers.googleblog.com/2020/03/run-arm-apps-on-android-emulator.html)
and [managed device ABI documentation](https://developer.android.com/reference/tools/gradle-api/8.12/com/android/build/api/dsl/ManagedVirtualDevice)
describe this supported testing path. No paid device service or self-hosted runner
is configured.

The jobs use pinned official Swift 6.4.0 toolchains and matching SDK bundles,
NDK 30.0.16248370, Gradle 8.11.1, Temurin 17.0.16+8, Android platform 35 revision 2,
build tools 35.0.0, command tools 19.0, platform tools 37.0.1 and emulator 37.1.11.
AGP 8.10.1 and Kotlin 2.1.21 remain pinned in Gradle; Bun is 1.4.2.
`scripts/ci-inputs.json` locks artifact URLs, versions and SHA-256 values. Google
archive hashes were computed from the exact downloads after checking the official
repository metadata's checksums. Swift SDK and Gradle hashes come from their
official installation/distribution records. Toolchain archives are also locked by
their computed SHA-256. Installers reject checksum mismatches and refuse to
overwrite an existing toolchain directory. Hosted runner OS images and Linux
system libraries are managed by GitHub/Ubuntu; their exact environment is recorded,
not claimed to be an immutable full OS image.

## Shared results and failures

The same `bridge.json`, `structure.json`, `recovery.json` and `documents.json` inputs
execute through each runtime. Each report contains input SHA-256 values and every
actual response, including successful documents, snapshots, histories, receipts,
selection positions, recovery proposals and explicit protocol/document failures.
The fixture executors also check the expected documents, equality invariants,
author undo and migration results before publishing a complete transcript.

`runtime-parity` requires all runtime jobs to succeed and exactly one report from
each matrix entry. It rejects stale input hashes, missing fixtures, partial
transcripts and differing responses. Object keys are canonicalized; array order,
text, IDs, marks and errors remain significant. A compile-only or skipped job does
not pass this gate.

Reruns can retain several artifacts with the same runtime name. The parity job
selects the newest creation timestamp for each of the five expected artifact
names and downloads those exact IDs. Metadata must belong to this workflow run
and source revision; missing, expired, empty or ambiguous latest artifacts fail.
It never falls back to an older report when newer evidence is invalid. The
complete-input, transcript and measurement verifiers still apply to selected
artifacts. Earlier failed-attempt diagnostics remain available.

Diagnostic artifacts retain reports, toolchain inputs, build/test output, Android
device properties/logcat and Playwright failure evidence for seven days, including
failed runs. Built native libraries and WASM binaries are not published as packages
or uploaded in these diagnostic artifacts. Private distribution and clean consumer
installation remain ST-34/ST-106 gates.

## Repeatable commands

The installer requires a fresh disposable directory, Python 3, archive tools, the
listed host libraries and Java for Android. CI runs it with a job-specific
`RUNNER_TEMP` directory. It prints the resulting compiler/SDK paths and writes
them to `GITHUB_ENV` when available; local callers use those paths explicitly.

```sh
python3 scripts/install-ci-toolchains.py apple /tmp/editor-apple-toolchains
python3 scripts/install-ci-toolchains.py wasm /tmp/editor-wasm-toolchains
python3 scripts/install-ci-toolchains.py android /tmp/editor-android-toolchains --api 26

"$SWIFT_BIN" test
"$SWIFT_BIN" build --product editor-bridge
bun scripts/run-native-compatibility.mjs .build/debug/editor-bridge

ANDROID_ABIS=x86_64 sh scripts/build-android.sh
python3 scripts/run-android-ci.py 26 x86_64

bun run build:wasm
COMPATIBILITY_OUTPUT=/tmp/editor-wasm-reports bunx playwright test --config playwright.swift.config.ts
bun scripts/compare-runtime-reports.mjs /path/to/downloaded/runtime-artifacts
```

The runtime jobs also exercise the short [measurement harness](editor-performance.md)
smoke profile. Its reports verify workload execution and preserved content;
numeric performance thresholds remain separate ST-94 acceptance.

This CI gate does not complete native menus/rich authoring, system IME or
accessibility, all Apple-family/minimum/current interaction, physical Android
devices, the full reference relay matrix, browser-process offline asset loading,
production React migration or accepted performance budgets. Those remain the
independent ST-94 and ST-97–ST-106 requirements. A successful PR run must still be
followed by a verified default-branch run after reviewed merge.
