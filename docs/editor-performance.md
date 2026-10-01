# Editor measurements

ST-94 measures artifacts, initialization, ordinary editing and growing offline
histories before numeric budgets are chosen. Passing these checks verifies the
workload and its preserved content; it does not accept a performance budget.

## Workloads and correctness

`benchmarks/workloads.json` is the shared, versioned input. Its 17 root blocks
contain Unicode, marked text, atomic references, nested checklists, a toggle,
table, code, image metadata, math and opaque extensions. Assets are host-owned;
the measurement runners do not fetch them or render the document.

Both collaboration versions run the same scenarios. Ordinary editing performs
24 insertions per author. History workloads perform 128, 512 or 2,048 insertions
per author. Two disconnected authors insert into the same text field and format
their own content, then exchange reversed and duplicated batches. Each run checks:

- Both replicas converge without losing either author's text, original Unicode,
  unrelated blocks, formatting, references or metadata.
- An already received batch is harmless, and a fresh replica replays the full
  history to the same document.
- Saves and exact receipts retain all `2 * editsPerAuthor + 2` transactions.
- Reopening restores content and receipts. Local undo removes the local format
  and one local character while retaining the remote italic mark and every remote
  character; redo restores the converged document.

No transport, account or production service is required. These are engine/adapter
measurements, separate from [local relay acceptance](local-sync-lab.md), system
input, rendering, accessibility and physical-device interaction.

The default `baseline` profile runs three recorded repetitions after one excluded
warmup per case. `smoke` runs two versions with eight edits per author, one recorded
repetition and no warmup. Explicit case/repeat/warmup overrides are recorded in
the report; a short or filtered run cannot claim the full default baseline.

## Measured boundaries

Native measurements use a caller-supplied `editor-bridge` process. Build it with
release optimization for baseline results. Round-trip timings include JSON,
standard-input/output pipes and response parsing. They are not bare Swift API
latencies. Fresh-process initialization includes launch and the first empty
session, separately from per-workload session creation.

Android measures `NativeEngine.call` in a fresh instrumentation process, using
release Swift libraries and a debug Kotlin/test host. JSON/UTF-8 conversion and
JNI copies are included. Initial JNI access includes library loading and the first
empty session, not Activity startup. Record the actual API, selected JNI ABI, ELF
machine, virtual hardware, VM and heap limits. ARM translation and an emulator are
not physical-device performance baselines.

WASM measures `SwiftEditorRuntime.call`, including JSON/UTF-8 and WASM memory
copies. Initialization separates compilation, instantiation of the compiled
module and the first empty session. Module bytes are fetched before timing;
network transfer, React rendering and input-to-frame latency are excluded.

All operation clocks are monotonic. Reports retain individual call durations and
nearest-rank median/p95, totals and extrema. Percentiles summarize calls within
each recorded repetition; they are not percentiles of separate app launches.
Warmup/cache behavior, hardware, OS/browser/runtime and source revision are recorded.
OS disk caches, browser compilation caches and background load are uncontrolled;
none of these measurements claims disk-cold startup or isolated laboratory load.
Run large local workloads sequentially to avoid measuring competing runners.

Artifact reports include exact hashes and raw sizes. WASM also records computed
gzip level-9 size; this does not prove deployed compression. Native CLI size
excludes its Apple system Swift libraries. Android's three selected-ABI libraries
include the static Swift runtime and NDK C++ runtime, plus APK compression sizes.
These boundaries differ and must not be compared as equivalent installed app sizes.
Snapshot/exchange sizes describe the host's JSON serialization; encoders can differ
in escaping. Exact history/receipt counts and final content are compared separately.

## Reproduce

Use the pinned toolchains and environment described in [runtime CI](runtime-ci.md).
The runners write incomplete reports on failure and never publish packages.

```sh
"$SWIFT_BIN" build -c release --product editor-bridge
bun scripts/run-native-performance.mjs .build/release/editor-bridge

bun run build:wasm
PERFORMANCE_OUTPUT=test-results/performance bunx playwright test \
  --config playwright.performance.config.ts

# The pinned disposable-emulator driver builds/installs a single-ABI test APK.
# It also executes the ordinary compatibility fixtures before measurements.
python3 scripts/run-android-ci.py 35 arm64-v8a --performance-profile baseline

# A small harness check; this is not a long-history baseline.
PERFORMANCE_PROFILE=smoke bun scripts/run-native-performance.mjs
bun test tests/performance-report.test.ts
```

For an already running approved Android test emulator, build
`:editor:assembleDebugAndroidTest`, install the test APK with its explicit ABI and
run only `studio.seventwo.blockeditor.PerformanceTest`. Supply instrumentation
arguments `expectedAbi`, `sourceCommit` and `performanceProfile=baseline`.
Optional `performanceCases` is comma-separated; `performanceRepetitions` and
`performanceWarmups` override repeat counts. The report is
`files/performance/android.json` in the test package. Preserve the existing emulator;
the disposable CI driver owns and resets only its job-specific AVD.

Native/browser equivalents are `PERFORMANCE_CASES`, `PERFORMANCE_REPETITIONS` and
`PERFORMANCE_WARMUPS`. For example, a single screening repetition of every case:

```sh
PERFORMANCE_REPETITIONS=1 PERFORMANCE_WARMUPS=0 \
  bun scripts/run-native-performance.mjs .build/release/editor-bridge
```

## CI and evidence

The existing runtime jobs execute the short smoke profile in native Swift, API 26
x86_64 JNI, API 35 x86_64/translated ARM64 JNI and Chromium/WebKit/Firefox WASM.
`runtime-parity` still requires all original complete compatibility transcripts.
It additionally compares measurement reports, requiring the exact workload hash,
source revision, expected cases/repetitions, call counts, finite consistent timings,
retained history/receipts and matching final documents. Missing, stale, failed or
partial measurements fail. Actual-report negative tests cover incomplete samples,
missing calls, shortened workloads, invalid clocks, fabricated aggregates and lost
receipts. Numeric timing thresholds are deliberately absent until budgets are agreed.

```sh
bun scripts/compare-performance-reports.mjs test-results/runtime-reports \
  native,android-api26-x86_64,android-api35-x86_64,android-api35-arm64-v8a,wasm-chromium,wasm-webkit,wasm-firefox smoke
```

Local comparisons can name only the runtimes actually executed. Omitting the final
profile argument permits explicitly recorded overrides; all selected runtimes must
still have identical options and complete results. The verifier checks the current
checkout revision and workload by default. An archive comparison can explicitly
pass `--source=<recorded-40-character-revision>`; it reports that this verifies
historical data, not measurements of the current checkout. Historical reports
must not be relabeled as current evidence.

Larger minimum/current-device baselines, sustained editing, peak memory, rendered
input latency, resource thresholds, compaction and numerical budget agreement remain
separate acceptance. Passing a 4,098-change history cannot establish unbounded
history performance or eliminate the retention/recovery limits.
